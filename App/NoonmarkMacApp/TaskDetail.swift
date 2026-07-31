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
                EditableDetailTitleRow(
                    definition.title,
                    ownerID:
                    "task:\(trace.chainID.description):title",
                    editable: canRenameTitle
                ) {
                    await store.autosaveTraceTitle(
                        traceID: trace.id,
                        title: $0
                    )
                }
            } description: {
                DetailDescriptionBlock(
                    ownerID:
                    "trace:\(trace.id.description):description",
                    text: trace.descriptionText ?? "",
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: canEditText,
                    onPersist: {
                        await store.autosaveTraceText(
                            traceID: trace.id,
                            descriptionText: $0
                        )
                    }
                )
            }

            HStack {
                StatusChip(status: trace.status)
                Text("\(store.displayDate(trace.date)) \(store.weekday(trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            TraceLifecycleSummary(trace: trace)
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
                taskTitle: definition.title
            )
            DetailSection(store.copy.subtasksTitle, showsTitle: false) {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(
                            subtask: subtask,
                            surface: .dayDetail
                        )
                    }
                    if subtasks.isEmpty && !canAddSubtask {
                        InlineEmptyHint(store.copy.noSubtasks)
                    }
                    if canAddSubtask {
                        NoonmarkTransientMarkdownComposer(
                            draft: store.detailSubtaskTextDraft,
                            placeholder: store.copy.addSubtaskPlaceholder,
                            style: .compact,
                            showsSurface: true,
                            commitsOnReturn: true,
                            onCommit: { store.addDetailSubtask(traceID: trace.id) },
                            nativeAccessibilityIdentifier: SubtaskRowSurface
                                .dayDetail
                                .newEditorIdentifier(for: trace.id)
                        )
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
            CollapsibleTaskTrailSection(trace: trace)
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
        DetailSection(store.copy.completionProgressTitle, showsTitle: false) {
            DetailProgressControl(
                traceID: traceID,
                progress: progress,
                editable: editable,
                showsPercent: true
            )
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
        VStack(alignment: .leading, spacing: 8) {
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
                    .shadow(color: Theme.shadowRaised, radius: 3, y: 1)
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
    let ownerID: String
    let text: String
    let placeholder: String
    let editable: Bool
    let warm: Bool
    let fallback: String
    let onPersist: @MainActor (String) async -> Bool
    var nativeAccessibilityIdentifier: String?

    var body: some View {
        if editable {
            AutosavingMarkdownEditor(
                ownerID: ownerID,
                persistedText: text,
                placeholder: placeholder,
                style: .detailBody,
                warm: warm,
                showsSurface: false,
                onPersist: onPersist,
                nativeAccessibilityIdentifier:
                nativeAccessibilityIdentifier
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
            newNoteDraft: store.detailNoteTextDraft,
            onAppend: { store.appendTraceNote(traceID: traceID) },
            onEdit: { noteID, body, expectedUpdatedAt in
                await store.autosaveTraceNote(
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

@MainActor
private final class TaskNoteEditSession {
    let noteID: TaskNoteEntryID
    let originalBody: String
    var baselineUpdatedAt: Date
    var persistedBody: String
    var draft: String

    init(
        noteID: TaskNoteEntryID,
        originalBody: String,
        baselineUpdatedAt: Date,
        persistedBody: String,
        draft: String
    ) {
        self.noteID = noteID
        self.originalBody = originalBody
        self.baselineUpdatedAt = baselineUpdatedAt
        self.persistedBody = persistedBody
        self.draft = draft
    }
}

struct TaskNoteEntriesSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entries: [TaskNoteEntry]
    let editable: Bool
    let placeholder: String
    let newNoteDraft: NoonmarkTextInputDraft
    let onAppend: () -> Bool
    let onEdit:
        @MainActor (
            TaskNoteEntryID,
            String,
            Date
        ) async -> Date?
    let onDelete: (TaskNoteEntryID) -> Bool

    @State private var editSession: TaskNoteEditSession?

    var body: some View {
        if entries.isEmpty == false || editable {
            DetailSection(store.copy.noteSectionTitle, showsTitle: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        DetailNoteEntryRow(
                            entry: entry,
                            editable: editable,
                            allowsActions: editSession == nil,
                            isEditing: editSession?.noteID == entry.id,
                            persistedEditBody:
                            editSession?.noteID == entry.id
                                ? editSession?.persistedBody
                                    ?? entry.body
                                : entry.body,
                            editDraft:
                            editSession?.noteID == entry.id
                                ? editSession?.draft ?? entry.body
                                : entry.body,
                            onStartEditing: {
                                guard editSession == nil else { return }
                                editSession = TaskNoteEditSession(
                                    noteID: entry.id,
                                    originalBody: entry.body,
                                    baselineUpdatedAt: entry.updatedAt,
                                    persistedBody: entry.body,
                                    draft: entry.body
                                )
                            },
                            onCancelEditing: { [session = editSession] in
                                guard let session,
                                      session.noteID == entry.id
                                else { return }
                                Task { @MainActor in
                                    await cancelEditing(session)
                                }
                            },
                            onSaveEditing: { [session = editSession] in
                                guard let session,
                                      session.noteID == entry.id
                                else { return }
                                Task { @MainActor in
                                    await finishEditing(session)
                                }
                            },
                            onDraftChange: { [session = editSession] draft in
                                guard let session,
                                      session.noteID == entry.id
                                else { return }
                                session.draft = draft
                            },
                            onDraftAutosave: { [session = editSession] draft in
                                guard let session,
                                      session.noteID == entry.id
                                else { return false }
                                return await persistEditedDraft(
                                    session,
                                    draft: draft
                                )
                            },
                            onDelete: {
                                guard onDelete(entry.id) else { return }
                            }
                        )

                        if index < entries.count - 1 || editable {
                            RailDivider()
                        }
                    }

                    if editable {
                        NoonmarkTransientMarkdownComposer(
                            draft: newNoteDraft,
                            placeholder: placeholder,
                            style: .compact,
                            warm: true,
                            showsSurface: true,
                            height: 32,
                            commitsOnReturn: true,
                            onCommit: {
                                _ = onAppend()
                            },
                            nativeAccessibilityIdentifier: "detail.note.composer"
                        )
                            .foregroundStyle(Theme.text1)
                            .accessibilityIdentifier("detail.note.composer")
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "detail.note.composer.copy",
                                    verificationText: placeholder
                                )
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.noteBackground)
                )
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

    @discardableResult
    private func persistEditedDraft(
        _ session: TaskNoteEditSession,
        draft: String
    ) async -> Bool {
        session.draft = draft

        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return false }
        guard body != session.persistedBody else { return true }
        guard let updatedAt = await onEdit(
            session.noteID,
            body,
            session.baselineUpdatedAt
        ) else {
            return false
        }
        session.baselineUpdatedAt = updatedAt
        session.persistedBody = body
        return true
    }

    private func finishEditing(
        _ session: TaskNoteEditSession
    ) async {
        guard editSession === session else { return }
        if session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard onDelete(session.noteID) else { return }
            editSession = nil
            return
        }
        guard await persistEditedDraft(
            session,
            draft: session.draft
        ) else { return }
        guard editSession === session else { return }
        editSession = nil
    }

    private func cancelEditing(
        _ session: TaskNoteEditSession
    ) async {
        guard editSession === session else { return }
        guard session.persistedBody != session.originalBody else {
            editSession = nil
            return
        }
        guard await onEdit(
            session.noteID,
            session.originalBody,
            session.baselineUpdatedAt
        ) != nil else {
            return
        }
        guard editSession === session else { return }
        editSession = nil
    }
}

struct DetailNoteEntryRow: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entry: TaskNoteEntry
    let editable: Bool
    let allowsActions: Bool
    let isEditing: Bool
    let persistedEditBody: String
    let editDraft: String
    let onStartEditing: () -> Void
    let onCancelEditing: () -> Void
    let onSaveEditing: () -> Void
    let onDraftChange: (String) -> Void
    let onDraftAutosave:
        @MainActor (String) async -> Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                AutosavingMarkdownEditor(
                    ownerID:
                    "note:\(entry.id.description)",
                    persistedText: persistedEditBody,
                    placeholder: store.copy.editNotePlaceholder,
                    style: .body,
                    warm: true,
                    showsSurface: false,
                    height: 58,
                    persistencePolicy: .nonemptyTrimmed,
                    onDraftChange: onDraftChange,
                    onPersist: onDraftAutosave,
                    nativeAccessibilityIdentifier:
                    "detail.note.editor.\(entry.id.description)",
                    focusesOnAppear: true
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
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard editable, allowsActions else { return }
                        onStartEditing()
                    }
                    .background {
                        AppE2EViewAnchor(
                            identifier: "detail.note.body.\(entry.id.description)",
                            verificationText: entry.body
                        )
                    }
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

struct TraceLifecycleSummary: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        TaskLifecycleSummaryLine(
            accessibilityIdentifier:
            "detail.lifecycle-summary.\(trace.id.description)"
        ) {
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
            if let changedSource = store.changedSource(for: trace) {
                Text("·")
                    .foregroundStyle(Theme.text3)
                ChangedSourceButton(title: changedSource.definition.title) {
                    store.openChangedSource(from: trace)
                }
            }
            if trace.status == .returnedToPool {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Text(store.copy.returnedToPoolOnDay)
            }
            if let target = store.carryoverTarget(for: trace) {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Button(
                    trace.status == .deferred
                        ? store.copy.deferredToLink(
                            store.displayDate(target.date)
                        )
                        : store.copy.continuedToLink(
                            store.displayDate(target.date)
                        )
                ) {
                    store.openCarryoverTarget(from: trace)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            } else if let source = store.carryoverSource(for: trace) {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Button(
                    store.engine.carryoverKind(for: trace.id) == .deferral
                        ? store.copy.deferredFromLink(
                            store.displayDate(source.date)
                        )
                        : store.copy.continuedFromUnfinishedLink(
                            store.displayDate(source.date)
                        )
                ) {
                    store.openCarryoverSource(from: trace)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    var continuationText: String {
        trace.continuationSeq > 0
            ? store.copy.continuationOrdinal(trace.continuationSeq)
            : store.copy.firstEntry
    }

    var durationDays: Int {
        let traces = store.engine.traces.values
            .filter {
                $0.chainID == trace.chainID
                    && $0.date <= trace.date
                    && $0.formsDayHistory
            }
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
    let chainID: TaskChainID
    let currentTraceID: DayTraceID?

    init(trace: DayTrace) {
        chainID = trace.chainID
        currentTraceID = trace.id
    }

    init(chainID: TaskChainID, currentTraceID: DayTraceID? = nil) {
        self.chainID = chainID
        self.currentTraceID = currentTraceID
    }

    var entries: [TaskTrailEntry] {
        (try? store.engine.taskTrail(chainID: chainID)) ?? []
    }

    var currentEntryID: String? {
        guard let currentTraceID else { return nil }
        return entries.last { $0.traceID == currentTraceID }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isCurrent = entry.id == currentEntryID
                let isLast = index == entries.count - 1
                let nodeStyle = TimelineNodeStyle(
                    kind: entry.kind,
                    isCurrent: isCurrent,
                    label: store.copy.taskTrailEntryLabel(entry.kind)
                )
                HStack(alignment: .top, spacing: 8) {
                    TimelineNodeGlyph(style: nodeStyle)
                    .frame(width: 14)
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        TimelineEventHeader(
                            style: nodeStyle,
                            occurredAt: entry.occurredAt,
                            isCurrent: isCurrent
                        )
                        if entry.kind == .scheduled, let date = entry.date {
                            Text(store.copy.taskTrailScheduledFor(store.displayFullDate(date)))
                                .font(.noonmarkSystem(size: 9.5))
                                .foregroundStyle(Theme.text3)
                                .lineLimit(1)
                        }
                        if entry.kind == .changed,
                           let traceID = entry.traceID,
                           let trace = store.engine.traces[traceID],
                           let changedTarget = store.changedTarget(for: trace)
                        {
                            ChangedTargetButton(
                                title: changedTarget.definition.title,
                                compact: true
                            ) {
                                store.openChangedTarget(from: trace)
                            }
                            .padding(.top, 2)
                        }
                        if entry.kind == .createdFromChange,
                           let sourceTraceID = entry.relatedTraceID,
                           let sourceTrace = store.engine.traces[sourceTraceID],
                           let sourceDefinition = store.definition(for: sourceTrace)
                        {
                            ChangedSourceButton(
                                title: sourceDefinition.title,
                                compact: true
                            ) {
                                store.openTaskTrailTrace(sourceTrace)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.top, 1)
                    .padding(
                        .bottom,
                        isLast ? 0 : 6
                    )
                    .padding(.leading, 4)
                    .padding(.trailing, isCurrent ? 8 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrent ? Theme.accentSoft : Color.clear)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    if !isLast {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Theme.line2)
                                .frame(
                                    width: 1.5,
                                    height: max(0, proxy.size.height - 15)
                                )
                                .offset(x: 6.25, y: 15)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .background {
                    ZStack {
                        AppE2EViewAnchor(
                            identifier: "timeline.event.\(entry.id)",
                            verificationText: "\(entry.kind.rawValue)|\(nodeStyle.glyph)|\(nodeStyle.label)|\(store.displayExactDateTime(entry.occurredAt))"
                        )
                        if let traceID = entry.traceID,
                           entries.last(where: { $0.traceID == traceID })?.id == entry.id,
                           let trace = store.engine.traces[traceID],
                           trace.formsDayHistory
                        {
                            AppE2EViewAnchor(
                                identifier: "timeline.trace.\(trace.id.description)",
                                verificationText: "\(trace.status.rawValue)|\(trace.status.uiStyle.glyph)|\(store.copy.traceStatusLabel(trace.status))"
                            )
                        }
                    }
                }
            }
        }
    }
}

struct TimelineEventHeader: View {
    @EnvironmentObject private var store: NoonmarkStore
    let style: TimelineNodeStyle
    let occurredAt: Date
    let isCurrent: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                title
                Spacer(minLength: 2)
                timestamp
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                    Spacer(minLength: 0)
                }
                timestamp
            }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(style.label)
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(style.labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if isCurrent {
                TimelineCurrentBadge()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var timestamp: some View {
        Text(store.displayExactDateTime(occurredAt))
            .font(.noonmarkSystem(size: 9.5))
            .foregroundStyle(Theme.text3)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct TimelineNodeStyle {
    let label: String
    let glyph: String
    let labelColor: Color
    let glyphForeground: Color
    let glyphBackground: Color
    let glyphBorder: Color

    init(kind: TaskTrailEntryKind, isCurrent: Bool, label: String) {
        self.label = label
        let status: TraceStatus? = switch kind {
        case .createdInPool, .createdFromChange, .scheduled:
            nil
        case .completed:
            .completed
        case .unfinished:
            .unfinished
        case .deferred, .continued:
            .deferred
        case .changed:
            .changed
        case .returnedToPool:
            .returnedToPool
        case .abandoned:
            .abandoned
        }
        if let status {
            let style = status.uiStyle
            glyph = style.glyph
            labelColor = style.foreground
            glyphForeground = style.glyphForeground
            glyphBackground = style.glyphBackground
            glyphBorder = style.glyphBorder
        } else {
            glyph = switch kind {
            case .createdInPool: "+"
            case .createdFromChange: "↗"
            case .scheduled: "→"
            default: preconditionFailure("Outcome entries use trace status styling")
            }
            labelColor = kind == .scheduled ? Theme.accent : Theme.text2
            glyphForeground = kind == .scheduled ? Theme.accent : Theme.text2
            glyphBackground = kind == .scheduled ? Theme.accentSoft : Theme.panel2
            glyphBorder = kind == .scheduled && isCurrent ? Theme.accent : Theme.line2
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}
