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
                IconMenuButton(menuContent: {
                    PoolTaskContextMenu(task: task, surface: "detail-overflow")
                })
            })
            DetailPrimaryText {
                EditableDetailTitleRow(task.definition.title, editable: true) {
                    store.renamePoolTask(
                        chainID: task.chain.id,
                        title: $0,
                        immediately: true,
                        reportsSuccess: false
                    )
                }
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { task.definition.descriptionText ?? "" },
                        set: {
                            store.updatePoolTaskText(
                                chainID: task.chain.id,
                                descriptionText: $0,
                                immediately: true
                            )
                        }
                    ),
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: true
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
            DetailSection(store.copy.taskTrailTitle) {
                Timeline(chainID: task.chain.id)
            }
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
            MarkdownEditor(
                text: $store.detailSubtaskText,
                placeholder: store.copy.addSubtaskPlaceholder,
                style: .compact,
                commitsOnReturn: true,
                onCommit: { store.addPoolPlannedSubtask(chainID: task.chain.id) },
                nativeAccessibilityIdentifier: "pool.subtask.\(task.chain.id.description).new"
            )
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct PlannedSubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let chainID: TaskChainID
    let plannedSubtask: PlannedSubtask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1.5))
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 28)

            EditableSubtaskTitle(
                title: plannedSubtask.title,
                editable: true,
                accessibilityIdentifier: "pool.subtask.\(plannedSubtask.id.description).title"
            ) {
                store.renamePoolPlannedSubtask(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtask.id,
                    title: $0,
                    immediately: true
                )
            }
            .foregroundStyle(Theme.text1)
            .lineLimit(1)

            Spacer()

            Menu {
                ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                    Button {
                        store.setPoolPlannedSubtaskDifficulty(
                            chainID: chainID,
                            plannedSubtaskID: plannedSubtask.id,
                            difficulty: difficulty
                        )
                    } label: {
                        Label(
                            difficultyMenuTitle(difficulty),
                            systemImage: difficulty == plannedSubtask.difficulty ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.noonmarkSystem(size: 9, weight: .semibold))
                    Text(store.copy.subtaskDifficulty(plannedSubtask.difficulty, compact: true))
                    Image(systemName: "chevron.down")
                        .font(.noonmarkSystem(size: 8, weight: .bold))
                }
                .font(.noonmarkSystem(size: 9, weight: .bold))
                .foregroundStyle(plannedSubtask.difficulty == .hard ? Theme.warn : Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(plannedSubtask.difficulty == .hard ? Theme.warnSoft : Theme.chip))
                .overlay(Capsule().stroke(Theme.line2))
            }
            .buttonStyle(.plain)

            Button {
                store.removePoolPlannedSubtask(chainID: chainID, plannedSubtaskID: plannedSubtask.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.noonmarkSystem(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text3)
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

    private func difficultyMenuTitle(_ difficulty: SubtaskDifficulty) -> String {
        store.copy.subtaskDifficulty(difficulty)
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
            newNoteText: $store.detailNoteText,
            onAppend: { store.appendPoolNote(chainID: chainID) },
            onEdit: { noteID, body, expectedUpdatedAt in
                guard store.editPoolNote(
                    chainID: chainID,
                    noteID: noteID,
                    body: body,
                    expectedUpdatedAt: expectedUpdatedAt,
                    immediately: true
                ) else {
                    return nil
                }
                return store.engine.taskPool().first { task in
                    task.chain.id == chainID
                }?.chain.activeNoteEntries.first { entry in
                    entry.id == noteID
                }?.updatedAt
            },
            onDelete: { noteID in
                store.deletePoolNote(chainID: chainID, noteID: noteID)
            }
        )
    }
}
