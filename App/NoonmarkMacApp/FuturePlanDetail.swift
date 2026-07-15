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
                    store.renameTraceTitle(traceID: trace.id, title: $0)
                }
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                    ),
                    placeholder: store.copy.planDescriptionPlaceholder,
                    editable: true
                )
            }

            HStack(spacing: 8) {
                PlanMetaPill(text: store.copy.planDraft, color: Theme.navFuture)
                Text("\(store.displayDate(trace.date)) \(store.weekday(trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            PlanSummaryCard(items: [
                PlanSummaryItem(label: store.copy.dateTitle, value: store.displayDate(trace.date), color: Theme.navFuture),
                PlanSummaryItem(label: store.copy.priorityTitle, value: "\(trace.priority)", color: Theme.text2),
                PlanSummaryItem(label: store.copy.statusTitle, value: store.copy.notDue, color: Theme.text2)
            ])

            Notice(text: store.copy.futurePlanNotice, tone: .locked)

            TaskClassificationDetailSection(
                trace: trace,
                taskTitle: definition.title,
                editable: true
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

struct PlanSummaryItem {
    let label: String
    let value: String
    let color: Color
}

struct PlanSummaryCard: View {
    let items: [PlanSummaryItem]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label)
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 44, alignment: .leading)
                    Text(item.value)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
                        .foregroundStyle(item.color)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.navFuture.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}
