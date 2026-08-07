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

struct PoolDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(store.copy.navPool, onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(
                    accessibilityIdentifier:
                    "pool.detail-overflow.\(task.chain.id.description)",
                    menuContent: {
                    PoolTaskContextMenu(task: task, surface: "detail-overflow")
                    }
                )
            })
            DetailPrimaryText {
                EditableDetailTitleRow(
                    task.definition.title,
                    ownerID:
                    "task:\(task.chain.id.description):title",
                    editable: true
                ) {
                    await store.autosavePoolTaskTitle(
                        chainID: task.chain.id,
                        title: $0
                    )
                }
            } description: {
                DetailDescriptionBlock(
                    ownerID:
                    "task:\(task.chain.id.description):description",
                    text: task.definition.descriptionText ?? "",
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: true,
                    onPersist: {
                        await store.autosavePoolTaskText(
                            chainID: task.chain.id,
                            descriptionText: $0
                        )
                    }
                )
            }
            Text(store.copy.poolNoDayTodoNotice)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text3)
            DetailSection(store.copy.classificationAndLabelsTitle, showsTitle: false) {
                TaskClassificationEditor(
                    chainID: task.chain.id,
                    taskTitle: task.definition.title
                )
            }
            DetailSection(store.copy.subtasksTitle, showsTitle: false) {
                PoolPlannedSubtasksSection(task: task)
            }
            CollapsibleTaskTrailSection(chainID: task.chain.id)
            PoolNotesSection(chainID: task.chain.id, entries: task.chain.activeNoteEntries)
        }
    }
}

struct PoolPlannedSubtasksSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var plannedSubtasks: [PlannedSubtask] {
        task.definition.plannedSubtasks.sorted { $0.position < $1.position }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(plannedSubtasks) { plannedSubtask in
                PlannedSubtaskRow(chainID: task.chain.id, plannedSubtask: plannedSubtask)
            }
            NoonmarkTransientMarkdownComposer(
                draft: store.detailSubtaskTextDraft,
                placeholder: store.copy.addSubtaskPlaceholder,
                style: .compact,
                showsSurface: true,
                commitsOnReturn: true,
                onCommit: { store.addPoolPlannedSubtask(chainID: task.chain.id) },
                nativeAccessibilityIdentifier: "pool.subtask.\(task.chain.id.description).new"
            )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

struct PlannedSubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let chainID: TaskChainID
    let plannedSubtask: PlannedSubtask

    var body: some View {
        HStack(alignment: .top, spacing: SubtaskRowMetrics.controlSpacing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1.5))
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 28)

            SubtaskDifficultyDotMenu(
                difficulty: plannedSubtask.difficulty,
                copy: store.copy,
                isEnabled: true,
                accessibilityIdentifier:
                "pool.subtask.\(plannedSubtask.id.description).difficulty"
            ) { difficulty in
                store.setPoolPlannedSubtaskDifficulty(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtask.id,
                    difficulty: difficulty
                )
            }

            EditableSubtaskTitle(
                title: plannedSubtask.title,
                editable: true,
                accessibilityIdentifier: "pool.subtask.\(plannedSubtask.id.description).title"
            ) {
                await store.autosavePoolPlannedSubtaskTitle(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtask.id,
                    title: $0
                )
            }
            .foregroundStyle(Theme.text1)
            .lineLimit(1)

            Button {
                store.removePoolPlannedSubtask(chainID: chainID, plannedSubtaskID: plannedSubtask.id)
            } label: {
                MicroLabel(systemImage: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.copy.removeSubtaskAction)
            .accessibilityIdentifier(
                "pool.subtask.\(plannedSubtask.id.description).delete.ax"
            )
            .background {
                AppE2EViewAnchor(
                    identifier: "pool.subtask.\(plannedSubtask.id.description).delete"
                )
            }
            .help(store.copy.removeSubtaskAction)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "pool.subtask.\(plannedSubtask.id.description).row"
            )
        }
    }
}

struct PoolNotesSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let chainID: TaskChainID
    let entries: [TaskNoteEntry]

    var body: some View {
        TaskNoteEntriesSection(
            entries: entries,
            editable: true,
            placeholder: store.copy.noteComposerPlaceholder,
            newNoteDraft: store.detailNoteTextDraft,
            onAppend: { store.appendPoolNote(chainID: chainID) },
            onEdit: { noteID, body, expectedUpdatedAt in
                await store.autosavePoolNote(
                    chainID: chainID,
                    noteID: noteID,
                    body: body,
                    expectedUpdatedAt: expectedUpdatedAt
                )
            },
            onDelete: { noteID in
                store.deletePoolNote(chainID: chainID, noteID: noteID)
            }
        )
    }
}
