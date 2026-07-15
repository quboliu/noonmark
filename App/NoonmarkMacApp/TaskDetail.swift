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

struct TaskDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace
    let definition: TaskDefinition

    var progress: TraceProgress { store.engine.traceProgress(for: trace.id) }
    var subtasks: [Subtask] { store.subtasks(for: trace.id) }
    var canEditText: Bool { trace.status == .pending && trace.date >= store.today }
    var canRenameTitle: Bool { trace.status == .pending && trace.date >= store.today }
    var canEditManualProgress: Bool { trace.status == .pending && trace.date == store.today && subtasks.isEmpty }
    var canAddSubtask: Bool { trace.status == .pending && trace.date >= store.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(store.copy.taskDetailsTitle, onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    TaskContextMenu(trace: trace)
                })
            })
            DetailPrimaryText {
                EditableDetailTitleRow(definition.title, editable: canRenameTitle) {
                    store.renameTraceTitle(traceID: trace.id, title: $0)
                }
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                    ),
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: canEditText
                )
            }

            HStack {
                StatusChip(status: trace.status)
                Text("\(store.displayDate(trace.date)) \(store.weekday(trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            TraceContextCard(trace: trace)
            if trace.date < store.today {
                Notice(text: store.copy.historicalReadOnlyNotice, tone: .locked)
            }
            DetailProgressSection(
                traceID: trace.id,
                progress: progress,
                editable: canEditManualProgress
            )
            TaskClassificationDetailSection(
                trace: trace,
                taskTitle: definition.title,
                editable: canEditText
            )
            DetailSection(store.copy.subtasksTitle) {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(subtask: subtask)
                    }
                    if subtasks.isEmpty && !canAddSubtask {
                        Text(store.copy.noSubtasks)
                            .font(.noonmarkSystem(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                    if canAddSubtask {
                        MarkdownEditor(
                            text: $store.detailSubtaskText,
                            placeholder: store.copy.addSubtaskPlaceholder,
                            style: .compact,
                            commitsOnReturn: true,
                            onCommit: { store.addDetailSubtask(traceID: trace.id) }
                        )
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    }
                }
            }
            DetailSection(store.copy.taskTrailTitle) {
                Timeline(trace: trace)
            }
            DetailNotesSection(
                traceID: trace.id,
                entries: trace.activeNoteEntries,
                editable: canEditText,
                placeholder: store.copy.noteComposerPlaceholder
            )
        }
    }
}

struct DetailProgressSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let traceID: DayTraceID
    let progress: TraceProgress
    let editable: Bool

    var body: some View {
        if editable {
            DetailSection(store.copy.completionProgressTitle) {
                DetailProgressControl(
                    traceID: traceID,
                    progress: progress,
                    editable: editable,
                    showsPercent: true
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                DetailProgressHeader(progress: progress)
                DetailProgressControl(
                    traceID: traceID,
                    progress: progress,
                    editable: editable,
                    showsPercent: false
                )
            }
        }
    }
}

struct DetailProgressHeader: View {
    @EnvironmentObject private var store: NoonmarkStore
    let progress: TraceProgress

    var body: some View {
        HStack(spacing: 8) {
            Text(store.copy.completionProgressTitle)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            Spacer()
            DetailProgressPercent(progress: progress)
        }
    }
}

struct DetailProgressPercent: View {
    let progress: TraceProgress

    var body: some View {
        Text("\(progress.percent)%")
            .font(.noonmarkSystem(size: 13, weight: .bold))
            .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
            .monospacedDigit()
    }
}

struct DetailProgressControl: View {
    @EnvironmentObject private var store: NoonmarkStore
    let traceID: DayTraceID
    let progress: TraceProgress
    let editable: Bool
    let showsPercent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsPercent {
                HStack {
                    Spacer()
                    DetailProgressPercent(progress: progress)
                }
            }
            if editable {
                ManualProgressSlider(
                    percent: progress.percent,
                    floorPercent: progress.floorPercent
                ) { percent in
                    store.setManualProgress(traceID: traceID, percent: Double(percent))
                }
                if progress.floorPercent > 0 {
                    Text(store.copy.progressFloorNotice(progress.floorPercent))
                        .font(.noonmarkSystem(size: 10))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                StaticProgressBar(percent: progress.percent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            progress.mode == .weightedSubtasks
                ? store.copy.weightedProgressAccessibilityLabel
                : store.copy.manualProgressAccessibilityLabel
        )
        .accessibilityValue("\(progress.percent)%")
    }
}

struct ManualProgressSlider: View {
    @EnvironmentObject private var store: NoonmarkStore
    let percent: Int
    let floorPercent: Int
    let onChange: (Int) -> Void

    var normalizedPercent: CGFloat {
        CGFloat(clampedPercent) / 100
    }

    var clampedPercent: Int {
        min(max(percent, floorPercent), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.chip)
                    .frame(height: 6)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * normalizedPercent, height: 6)
                ForEach(Array(stride(from: 0, through: 100, by: 5)), id: \.self) { mark in
                    Rectangle()
                        .fill(mark <= clampedPercent ? Theme.accent.opacity(0.32) : Theme.line2)
                        .frame(width: 1, height: 9)
                        .offset(x: min(width - 1, width * CGFloat(mark) / 100))
                }
                Circle()
                    .fill(Theme.panel)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 1.8))
                    .shadow(color: Theme.accent.opacity(0.16), radius: 3, y: 1)
                    .offset(x: max(0, min(width - 12, width * normalizedPercent - 6)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(snappedPercent(for: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel(store.copy.manualProgressAccessibilityLabel)
        .accessibilityValue("\(clampedPercent)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onChange(adjustedPercent(by: 5))
            case .decrement:
                onChange(adjustedPercent(by: -5))
            @unknown default:
                break
            }
        }
    }

    private func snappedPercent(for x: CGFloat, width: CGFloat) -> Int {
        let rawPercent = Int((min(max(x / width, 0), 1) * 100).rounded())
        let snapped = Int((Double(rawPercent) / 5).rounded()) * 5
        return min(max(snapped, floorPercent), 100)
    }

    private func adjustedPercent(by delta: Int) -> Int {
        min(max(clampedPercent + delta, floorPercent), 100)
    }
}

struct StaticProgressBar: View {
    let percent: Int

    var normalizedPercent: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    var fillColor: Color {
        percent >= 100 ? Theme.ok : Theme.accent
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip)
                Capsule()
                    .fill(fillColor)
                    .frame(width: proxy.size.width * normalizedPercent)
            }
        }
        .frame(height: 6)
    }
}

struct EditableDetailText: View {
    @Binding var text: String
    let placeholder: String
    let editable: Bool
    let warm: Bool
    let fallback: String
    var nativeAccessibilityIdentifier: String?

    var body: some View {
        if editable {
            MarkdownEditor(
                text: normalizedBinding,
                placeholder: placeholder,
                style: .detailBody,
                warm: warm,
                showsSurface: false,
                nativeAccessibilityIdentifier: nativeAccessibilityIdentifier
            )
                .italic(warm)
                .foregroundStyle(warm ? Theme.text2 : Theme.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownText(text, fallback: fallback)
                .font(.noonmarkSystem(size: 12))
                .italic(warm)
                .foregroundStyle(warm ? Theme.text2 : Theme.text2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var normalizedBinding: Binding<String> {
        Binding(
            get: { text },
            set: { text = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : $0 }
        )
    }
}

struct DetailNotesSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let traceID: DayTraceID
    let entries: [TaskNoteEntry]
    let editable: Bool
    let placeholder: String

    var body: some View {
        TaskNoteEntriesSection(
            entries: entries,
            editable: editable,
            placeholder: placeholder,
            newNoteText: $store.detailNoteText,
            onAppend: { store.appendTraceNote(traceID: traceID) },
            onEdit: { noteID, body, expectedUpdatedAt in
                store.editTraceNote(
                    traceID: traceID,
                    noteID: noteID,
                    body: body,
                    expectedUpdatedAt: expectedUpdatedAt
                )
            },
            onDelete: { noteID in
                store.deleteTraceNote(traceID: traceID, noteID: noteID)
            }
        )
    }
}

private struct TaskNoteEditSession: Equatable {
    let noteID: TaskNoteEntryID
    let baselineUpdatedAt: Date
    var draft: String
}

struct TaskNoteEntriesSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entries: [TaskNoteEntry]
    let editable: Bool
    let placeholder: String
    @Binding var newNoteText: String
    let onAppend: () -> Bool
    let onEdit: (TaskNoteEntryID, String, Date) -> Bool
    let onDelete: (TaskNoteEntryID) -> Bool

    @State private var editSession: TaskNoteEditSession?

    var body: some View {
        if entries.isEmpty == false || editable {
            DetailSection(store.copy.noteSectionTitle) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        DetailNoteEntryRow(
                            entry: entry,
                            editable: editable,
                            allowsActions: editSession == nil,
                            isEditing: editSession?.noteID == entry.id,
                            editDraft: editDraftBinding(for: entry.id),
                            onStartEditing: {
                                guard editSession == nil else { return }
                                editSession = TaskNoteEditSession(
                                    noteID: entry.id,
                                    baselineUpdatedAt: entry.updatedAt,
                                    draft: entry.body
                                )
                            },
                            onCancelEditing: {
                                guard editSession?.noteID == entry.id else { return }
                                editSession = nil
                            },
                            onSaveEditing: {
                                guard let session = editSession,
                                      session.noteID == entry.id
                                else { return }
                                let body = session.draft.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                guard body.isEmpty == false else { return }
                                guard onEdit(
                                    entry.id,
                                    body,
                                    session.baselineUpdatedAt
                                ) else { return }
                                editSession = nil
                            },
                            onDelete: {
                                guard onDelete(entry.id) else { return }
                            }
                        )

                        if index < entries.count - 1 || editable {
                            Divider()
                                .overlay(Theme.line)
                        }
                    }

                    if editable {
                        MarkdownEditor(
                            text: $newNoteText,
                            placeholder: placeholder,
                            style: .compact,
                            warm: true,
                            showsSurface: false,
                            height: 32,
                            commitsOnReturn: true,
                            onCommit: {
                                _ = onAppend()
                            },
                            nativeAccessibilityIdentifier: "detail.note.composer"
                        )
                            .foregroundStyle(Theme.text1)
                            .accessibilityIdentifier("detail.note.composer")
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "detail.note.composer.copy",
                                    verificationText: placeholder
                                )
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.noteBackground))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityIdentifier("detail.note.section")
            .background {
                AppE2EViewAnchor(
                    identifier: "detail.note.section",
                    verificationText: store.copy.noteSectionTitle
                )
            }
            .onChange(of: entries.map(\.id)) { _, noteIDs in
                guard let editSession,
                      noteIDs.contains(editSession.noteID) == false
                else { return }
                self.editSession = nil
            }
        }
    }

    private func editDraftBinding(for noteID: TaskNoteEntryID) -> Binding<String> {
        Binding(
            get: {
                guard editSession?.noteID == noteID else { return "" }
                return editSession?.draft ?? ""
            },
            set: { draft in
                guard var session = editSession,
                      session.noteID == noteID
                else { return }
                session.draft = draft
                editSession = session
            }
        )
    }
}

struct DetailNoteEntryRow: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entry: TaskNoteEntry
    let editable: Bool
    let allowsActions: Bool
    let isEditing: Bool
    @Binding var editDraft: String
    let onStartEditing: () -> Void
    let onCancelEditing: () -> Void
    let onSaveEditing: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text(store.displayDateTime(entry.createdAt))
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if editable, allowsActions, !isEditing {
                    TaskNoteOverflowControl(
                        entryID: entry.id,
                        copy: store.copy,
                        onEdit: onStartEditing,
                        onDelete: onDelete
                    )
                    .frame(width: 18, height: 18)
                }
            }

            if isEditing {
                MarkdownEditor(
                    text: $editDraft,
                    placeholder: store.copy.editNotePlaceholder,
                    style: .body,
                    warm: true,
                    showsSurface: false,
                    height: 58,
                    nativeAccessibilityIdentifier: "detail.note.editor.\(entry.id.description)"
                )
                    .foregroundStyle(Theme.text1)
                    .frame(minHeight: 58)
                    .accessibilityIdentifier("detail.note.editor.\(entry.id.description)")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "detail.note.editor.state.\(entry.id.description)",
                            verificationText: store.copy.editNotePlaceholder
                        )
                    }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    TaskNoteTextActionControl(
                        title: store.copy.cancel,
                        identifier: "detail.note.cancel.\(entry.id.description)",
                        emphasis: .secondary,
                        action: onCancelEditing
                    )
                    TaskNoteTextActionControl(
                        title: store.copy.save,
                        identifier: "detail.note.save.\(entry.id.description)",
                        emphasis: .accent,
                        isEnabled: editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                        action: onSaveEditing
                    )
                }
            } else {
                MarkdownText(entry.body)
                    .font(.noonmarkSystem(size: 12))
                    .italic()
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("detail.note.entry.\(entry.id.description)")
        .background {
            AppE2EViewAnchor(
                identifier: "detail.note.entry.state.\(entry.id.description)",
                verificationText: isEditing ? editDraft : entry.body
            )
        }
    }
}

struct TraceContextCard: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(continuationText)
            Text("·")
                .foregroundStyle(Theme.text3)
            Text(store.copy.duration(durationDays))
            if let changedTarget = store.changedTarget(for: trace) {
                Text("·")
                    .foregroundStyle(Theme.text3)
                ChangedTargetButton(title: changedTarget.definition.title) {
                    store.openChangedTarget(from: trace)
                }
            }
            if trace.status == .returnedToPool {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Text(store.copy.returnedToPoolOnDay)
            }
            Spacer(minLength: 0)
        }
        .font(.noonmarkSystem(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    var continuationText: String {
        trace.continuationSeq > 0
            ? store.copy.continuationOrdinal(trace.continuationSeq)
            : store.copy.firstEntry
    }

    var durationDays: Int {
        let traces = store.engine.traces.values
            .filter { $0.chainID == trace.chainID && $0.date <= trace.date }
            .sorted { $0.date < $1.date }
        guard let first = traces.first else { return 1 }
        return max(
            1,
            NoonmarkStore.dayDistance(from: first.date, to: trace.date) + 1
        )
    }
}

struct Timeline: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        let chainTraces = store.engine.traces.values
            .filter { $0.chainID == trace.chainID }
            .sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chainTraces.enumerated()), id: \.element.id) { index, item in
                let isCurrent = item.id == trace.id
                let isLast = index == chainTraces.count - 1
                let presentedStatus: TraceStatus = item.status == .continued ? .unfinished : item.status
                let nodeStyle = TimelineNodeStyle(
                    status: item.status,
                    isCurrent: isCurrent,
                    label: store.copy.traceStatusLabel(presentedStatus)
                )
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        TimelineNodeGlyph(style: nodeStyle)
                        if !isLast {
                            Rectangle()
                                .fill(Theme.line2)
                                .frame(width: 1.5, height: 28)
                                .padding(.top, 1)
                        }
                    }
                    .frame(width: 14)
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(nodeStyle.label)
                                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                                .foregroundStyle(nodeStyle.labelColor)
                            if isCurrent {
                                TimelineCurrentBadge()
                            }
                            Spacer(minLength: 0)
                            Text("#\(item.continuationSeq + 1)")
                                .font(.noonmarkSystem(size: 10))
                                .foregroundStyle(Theme.text3)
                                .monospacedDigit()
                        }
                        Text("\(store.displayDate(item.date)) \(store.weekday(item.date))")
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text3)
                        if let changedTarget = store.changedTarget(for: item) {
                            ChangedTargetButton(
                                title: changedTarget.definition.title,
                                compact: true
                            ) {
                                store.openChangedTarget(from: item)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.top, 1)
                    .padding(.bottom, isLast ? 0 : 12)
                    .padding(.leading, 4)
                    .padding(.trailing, isCurrent ? 8 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrent ? Theme.accentSoft : Color.clear)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct TimelineNodeStyle {
    let label: String
    let glyph: String
    let labelColor: Color
    let glyphForeground: Color
    let glyphBackground: Color
    let glyphBorder: Color

    init(status: TraceStatus, isCurrent: Bool, label: String) {
        self.label = label
        switch status {
        case .pending:
            glyph = ""
            labelColor = Theme.accent
            glyphForeground = Theme.accent
            glyphBackground = Theme.panel
            glyphBorder = isCurrent ? Theme.accent : Theme.line2
        case .completed:
            glyph = status.uiStyle.glyph
            labelColor = Theme.ok
            glyphForeground = .white
            glyphBackground = Theme.ok
            glyphBorder = .clear
        case .unfinished:
            glyph = status.uiStyle.glyph
            labelColor = Theme.warn
            glyphForeground = Theme.warn
            glyphBackground = Theme.warnSoft
            glyphBorder = .clear
        case .continued:
            glyph = TraceStatus.unfinished.uiStyle.glyph
            labelColor = Theme.warn
            glyphForeground = Theme.warn
            glyphBackground = Theme.warnSoft
            glyphBorder = .clear
        case .changed, .returnedToPool, .abandoned:
            glyph = status.uiStyle.glyph
            labelColor = status.uiStyle.foreground
            glyphForeground = status.uiStyle.glyphForeground
            glyphBackground = status.uiStyle.glyphBackground
            glyphBorder = status.uiStyle.glyphBorder
        }
    }
}

struct TimelineNodeGlyph: View {
    let style: TimelineNodeStyle

    var body: some View {
        Text(style.glyph)
            .font(.noonmarkSystem(size: 8.5, weight: .bold))
            .foregroundStyle(style.glyphForeground)
            .frame(width: 14, height: 14)
            .background(Circle().fill(style.glyphBackground))
            .overlay(Circle().stroke(style.glyphBorder, lineWidth: 1.5))
    }
}

struct TimelineCurrentBadge: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        Text(store.copy.currentLocation)
            .font(.noonmarkSystem(size: 9, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}
