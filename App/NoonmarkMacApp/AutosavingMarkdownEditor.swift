import Foundation
import NoonmarkMacRuntime
import SwiftUI

enum MarkdownDraftPersistencePolicy {
    case verbatim
    case nonemptyTrimmed

    func normalized(_ text: String) -> String? {
        switch self {
        case .verbatim:
            text
        case .nonemptyTrimmed:
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty
        }
    }
}

struct AutosavingMarkdownEditor: View {
    @EnvironmentObject private var store: NoonmarkStore

    let ownerID: String
    let persistedText: String
    let placeholder: String
    var style: MarkdownEditorStyle = .body
    var warm = false
    var showsSurface = true
    var height: CGFloat?
    var commitsOnReturn = false
    var persistencePolicy:
        MarkdownDraftPersistencePolicy = .verbatim
    var onDraftChange: ((String) -> Void)?
    let onPersist: @MainActor (String) async -> Bool
    var nativeAccessibilityIdentifier: String?
    var focusesOnAppear = false
    var focusRequest = 0

    var body: some View {
        AutosavingMarkdownEditorSession(
            ownerID: ownerID,
            persistedText: persistedText,
            placeholder: placeholder,
            style: style,
            warm: warm,
            showsSurface: showsSurface,
            height: height,
            commitsOnReturn: commitsOnReturn,
            persistencePolicy: persistencePolicy,
            onDraftChange: onDraftChange,
            onPersist: onPersist,
            onPublishPending: {
                await store.publishDeferredEngineMutations()
            },
            lifecycleFlushCoordinator:
            store.inputDraftFlushCoordinator,
            nativeAccessibilityIdentifier:
            nativeAccessibilityIdentifier,
            focusesOnAppear: focusesOnAppear,
            focusRequest: focusRequest
        )
        .id(ownerID)
    }
}

@MainActor
private final class AutosavingMarkdownEditorSessionState {
    var autosaveGate: IMETextDraftAutosaveGate
    let autosaveScheduler: InputDraftAutosaveScheduler
    var pendingPersistedText: String?
    var canonicalizesAfterSuccess = false
    var lastNativeText: String
    var lastAcknowledgedText: String
    let lifecycleRegistrationToken = UUID()

    init(ownerID: String, persistedText: String) {
        autosaveGate = IMETextDraftAutosaveGate(
            ownerID: ownerID
        )
        autosaveScheduler = InputDraftAutosaveScheduler()
        lastNativeText = persistedText
        lastAcknowledgedText = persistedText
    }
}

private struct AutosavingMarkdownEditorSession: View {
    let ownerID: String
    let persistedText: String
    let placeholder: String
    let style: MarkdownEditorStyle
    let warm: Bool
    let showsSurface: Bool
    let height: CGFloat?
    let commitsOnReturn: Bool
    let persistencePolicy: MarkdownDraftPersistencePolicy
    let onDraftChange: ((String) -> Void)?
    let onPersist: @MainActor (String) async -> Bool
    let onPublishPending: @MainActor () async -> Void
    let lifecycleFlushCoordinator:
        InputDraftFlushCoordinator
    let nativeAccessibilityIdentifier: String?
    let focusesOnAppear: Bool
    let focusRequest: Int

    @State private var draft: String
    @State private var sessionState:
        AutosavingMarkdownEditorSessionState

    init(
        ownerID: String,
        persistedText: String,
        placeholder: String,
        style: MarkdownEditorStyle,
        warm: Bool,
        showsSurface: Bool,
        height: CGFloat?,
        commitsOnReturn: Bool,
        persistencePolicy: MarkdownDraftPersistencePolicy,
        onDraftChange: ((String) -> Void)?,
        onPersist: @escaping @MainActor (String) async -> Bool,
        onPublishPending:
        @escaping @MainActor () async -> Void,
        lifecycleFlushCoordinator:
        InputDraftFlushCoordinator,
        nativeAccessibilityIdentifier: String?,
        focusesOnAppear: Bool,
        focusRequest: Int
    ) {
        self.ownerID = ownerID
        self.persistedText = persistedText
        self.placeholder = placeholder
        self.style = style
        self.warm = warm
        self.showsSurface = showsSurface
        self.height = height
        self.commitsOnReturn = commitsOnReturn
        self.persistencePolicy = persistencePolicy
        self.onDraftChange = onDraftChange
        self.onPersist = onPersist
        self.onPublishPending = onPublishPending
        self.lifecycleFlushCoordinator =
            lifecycleFlushCoordinator
        self.nativeAccessibilityIdentifier =
            nativeAccessibilityIdentifier
        self.focusesOnAppear = focusesOnAppear
        self.focusRequest = focusRequest
        _draft = State(initialValue: persistedText)
        _sessionState = State(
            initialValue: AutosavingMarkdownEditorSessionState(
                ownerID: ownerID,
                persistedText: persistedText
            )
        )
    }

    var body: some View {
        MarkdownEditor(
            text: $draft,
            placeholder: placeholder,
            style: style,
            warm: warm,
            showsSurface: showsSurface,
            height: height,
            commitsOnReturn: commitsOnReturn,
            defersMarkedTextBindingUpdates: true,
            onCommit: finishEditing,
            onEndEditing: finishEditing,
            onNativeSnapshot: nativeSnapshotDidChange,
            nativeAccessibilityIdentifier:
            nativeAccessibilityIdentifier,
            focusesOnAppear: focusesOnAppear,
            focusRequest: focusRequest
        )
        .onChange(of: persistedText) { _, newValue in
            synchronizePersistedText(newValue)
        }
        .onAppear {
            registerLifecycleFlush()
        }
        .onDisappear {
            let coordinator =
                lifecycleFlushCoordinator
            let token =
                sessionState.lifecycleRegistrationToken
            Task { @MainActor in
                guard await flushForLifecycle() else {
                    return
                }
                coordinator.unregister(
                    ownerID: ownerID,
                    token: token
                )
            }
        }
    }

    private func nativeSnapshotDidChange(
        _ snapshot: NativeMarkdownEditorSnapshot
    ) {
        let textChanged =
            sessionState.lastNativeText != snapshot.text
        sessionState.lastNativeText = snapshot.text
        if sessionState.pendingPersistedText
            != snapshot.text
        {
            sessionState.pendingPersistedText = nil
        }
        if textChanged, snapshot.isComposing == false {
            onDraftChange?(snapshot.text)
        }
        let schedule =
            sessionState.autosaveGate
                .nativeSnapshotDidChange(
                    textChanged: textChanged,
                    isComposing: snapshot.isComposing
                )
        apply(schedule)
    }

    private func finishEditing() {
        sessionState.canonicalizesAfterSuccess = true
        let schedule =
            sessionState.autosaveGate.requestFlush()
        apply(schedule)
        if schedule == nil,
           sessionState.autosaveGate.isComposing == false,
           sessionState.autosaveGate
           .hasPersistenceInFlight == false
        {
            Task { @MainActor in
                await onPublishPending()
            }
        }
    }

    private func apply(
        _ schedule: IMETextDraftAutosaveGate.Schedule?
    ) {
        sessionState.autosaveScheduler.replace(
            with: schedule
        ) { schedule in
            guard sessionState.autosaveGate
                .permitsAutosave(schedule)
            else {
                return
            }
            _ = await persistDraft(for: schedule)
        }
    }

    private func registerLifecycleFlush() {
        let token =
            sessionState.lifecycleRegistrationToken
        lifecycleFlushCoordinator.register(
            ownerID: ownerID,
            token: token
        ) {
            await flushForLifecycle()
        }
    }

    /// Forces the newest native draft through the normal ordered persistence
    /// path. There is deliberately no timeout: termination remains pending
    /// until durable storage answers, and a rejected write cancels termination.
    private func flushForLifecycle() async -> Bool {
        sessionState.canonicalizesAfterSuccess = true
        sessionState.autosaveScheduler.cancel()
        guard sessionState.autosaveGate
            .isComposing == false
        else {
            return false
        }
        while sessionState.autosaveGate
            .hasPersistenceInFlight
        {
            await Task.yield()
        }
        guard sessionState.autosaveGate
            .hasUnflushedChanges
        else {
            await onPublishPending()
            return true
        }
        guard let schedule =
            sessionState.autosaveGate.requestFlush()
        else {
            return false
        }
        guard await persistDraft(for: schedule) else {
            return false
        }
        if sessionState.autosaveGate
            .hasUnflushedChanges
        {
            return await flushForLifecycle()
        }
        await onPublishPending()
        return true
    }

    @discardableResult
    private func persistDraft(
        for schedule: IMETextDraftAutosaveGate.Schedule
    ) async -> Bool {
        guard let normalized =
            persistencePolicy.normalized(draft)
        else {
            guard sessionState
                .canonicalizesAfterSuccess
            else {
                sessionState.autosaveScheduler.cancel()
                return true
            }
            draft = sessionState.lastAcknowledgedText
            sessionState.lastNativeText =
                sessionState.lastAcknowledgedText
            onDraftChange?(
                sessionState.lastAcknowledgedText
            )
            sessionState.autosaveGate
                .discardLocalChanges()
            sessionState.autosaveScheduler.cancel()
            sessionState.canonicalizesAfterSuccess =
                false
            await onPublishPending()
            return true
        }
        guard let request =
            sessionState.autosaveGate
            .beginPersistence(for: schedule)
        else {
            return sessionState.autosaveGate
                .hasUnflushedChanges == false
        }
        let rawDraft = draft
        let succeeded: Bool
        if normalized
            == sessionState.lastAcknowledgedText
        {
            succeeded = true
        } else {
            let persistence = Task { @MainActor in
                await onPersist(normalized)
            }
            succeeded = await persistence.value
        }
        guard succeeded else {
            apply(
                sessionState.autosaveGate
                    .persistenceDidFail(request)
            )
            return false
        }
        sessionState.pendingPersistedText = normalized
        sessionState.lastAcknowledgedText = normalized
        apply(
            sessionState.autosaveGate
                .persistenceDidSucceed(request)
        )
        let shouldPublishPending =
            sessionState.canonicalizesAfterSuccess
        if sessionState.canonicalizesAfterSuccess,
           draft == rawDraft,
           draft != normalized
        {
            draft = normalized
            sessionState.lastNativeText = normalized
            onDraftChange?(normalized)
        }
        sessionState.canonicalizesAfterSuccess = false
        if shouldPublishPending {
            await onPublishPending()
        }
        return true
    }

    private func synchronizePersistedText(
        _ newValue: String
    ) {
        if sessionState.pendingPersistedText
            == newValue
        {
            sessionState.pendingPersistedText = nil
            sessionState.lastAcknowledgedText =
                newValue
            return
        }
        guard sessionState.autosaveGate
            .isComposing == false,
            sessionState.autosaveGate
            .hasUnflushedChanges == false
        else {
            return
        }
        sessionState.autosaveGate
            .acknowledgeWithoutPersistence()
        sessionState.lastAcknowledgedText = newValue
        sessionState.autosaveScheduler.cancel()
        if draft != newValue {
            draft = newValue
            sessionState.lastNativeText = newValue
            onDraftChange?(newValue)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
