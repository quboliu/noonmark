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

struct FuturePlanDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace
    let definition: TaskDefinition

    private var isRecurringOccurrence: Bool {
        store.engine.chains[trace.chainID]?.cycleMembership != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(store.copy.planDetailsTitle, onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button(store.copy.openDay) { openDay() }
                    TaskContextMenu(trace: trace)
                })
            })
            DetailPrimaryText {
                EditableDetailTitleRow(definition.title, editable: true) {
                    store.renameTraceTitle(
                        traceID: trace.id,
                        title: $0,
                        immediately: true,
                        reportsSuccess: false
                    )
                }
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { trace.descriptionText ?? "" },
                        set: {
                            store.updateTraceText(
                                traceID: trace.id,
                                descriptionText: $0,
                                immediately: true
                            )
                        }
                    ),
                    placeholder: store.copy.planDescriptionPlaceholder,
                    editable: true
                )
            }

            HStack(spacing: NoonmarkVisualMetrics.futurePlanMetadataSpacing) {
                PlanMetaPill(text: store.copy.planDraft, color: Theme.navFuture)
                Text(store.displayDate(trace.date))
                Text("\(store.copy.priorityTitle) \(trace.priority)")
                Text(store.copy.notDue)
            }
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text3)
            .lineLimit(1)

            if let source = store.carryoverSource(for: trace) {
                Button {
                    store.openCarryoverSource(from: trace)
                } label: {
                    Text(
                        store.engine.carryoverKind(for: trace.id) == .deferral
                            ? store.copy.deferredFromLink(
                                store.displayDate(source.date)
                            )
                            : store.copy.continuedFromUnfinishedLink(
                                store.displayDate(source.date)
                            )
                    )
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
            }

            Notice(
                text: store.copy.futurePlanNotice(
                    isRecurringOccurrence: isRecurringOccurrence
                ),
                tone: .locked
            )

            TaskClassificationDetailSection(
                trace: trace,
                taskTitle: definition.title
            )

            DetailSection(store.copy.taskTrailTitle) {
                Timeline(trace: trace)
            }

            DetailNotesSection(
                traceID: trace.id,
                entries: trace.activeNoteEntries,
                editable: true,
                placeholder: store.copy.noteComposerPlaceholder
            )
        }
    }

    private func openDay() {
        store.selectedDate = trace.date
        store.page = .day
        store.selectTrace(trace.id)
    }
}
