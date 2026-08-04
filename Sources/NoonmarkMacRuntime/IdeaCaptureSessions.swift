import Combine
import Foundation
import NoonmarkCore

@MainActor
public protocol IdeaComposerDraftStoring: AnyObject {
    func load() -> String
    func save(_ text: String)
}

@MainActor
public final class IdeaComposerDraftRepository: IdeaComposerDraftStoring {
    public static let defaultStorageKey = "Noonmark.IdeaComposerDraft.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> String {
        defaults.string(forKey: storageKey) ?? ""
    }

    public func save(_ text: String) {
        if text.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(text, forKey: storageKey)
        }
    }
}

@MainActor
public final class InMemoryIdeaComposerDraftRepository:
    IdeaComposerDraftStoring
{
    private var text: String

    public init(_ text: String = "") {
        self.text = text
    }

    public func load() -> String {
        text
    }

    public func save(_ text: String) {
        self.text = text
    }
}

public enum IdeaComposerSubmissionState: Equatable, Sendable {
    case idle
    case saving
    case succeeded
    case empty
    case failed
}

/// Shared transient composer state for both the Ideas page and the global
/// capture panel. The repository is device-local and never enters task data,
/// sync payloads, or diagnostics.
@MainActor
public final class IdeaComposerSession: ObservableObject {
    @Published public private(set) var text: String
    @Published public private(set) var submissionState:
        IdeaComposerSubmissionState = .idle
    @Published public private(set) var failureMessage: String?

    private let repository: any IdeaComposerDraftStoring
    private var successGeneration: UInt64 = 0

    public init(repository: any IdeaComposerDraftStoring) {
        self.repository = repository
        text = repository.load()
    }

    public func updateText(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        submissionState = .idle
        failureMessage = nil
        repository.save(text)
    }

    @discardableResult
    public func submit(
        using capture: (String) -> Bool
    ) -> Bool {
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.isEmpty == false else {
            submissionState = .empty
            return false
        }

        failureMessage = nil
        submissionState = .saving
        guard capture(normalized) else {
            submissionState = .failed
            return false
        }

        text = ""
        failureMessage = nil
        repository.save("")
        presentSuccess()
        return true
    }

    public func dismiss() {
        repository.save(text)
    }

    public func clear() {
        successGeneration &+= 1
        text = ""
        submissionState = .idle
        failureMessage = nil
        repository.save("")
    }

    public func setFailureMessage(_ message: String) {
        failureMessage = message
    }

    private func presentSuccess() {
        successGeneration &+= 1
        let generation = successGeneration
        submissionState = .succeeded
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self,
                  successGeneration == generation,
                  submissionState == .succeeded
            else { return }
            submissionState = .idle
        }
    }
}

public enum IdeaInlineEditorSaveState: Equatable, Sendable {
    case idle
    case saving
    case succeeded
    case empty
    case failed
}

public enum IdeaInlineEditorEndReason: Equatable, Sendable {
    case submit
    case explicitCancel
    case blur
    case navigation
}

/// Owns the one active inline edit independently of the memo row's visual
/// presentation, so a later row redesign cannot change save and recovery
/// semantics.
@MainActor
public final class IdeaInlineEditorSession: ObservableObject {
    @Published public private(set) var ideaID: IdeaID?
    @Published public private(set) var originalText = ""
    @Published public private(set) var draftText = ""
    @Published public private(set) var saveState:
        IdeaInlineEditorSaveState = .idle
    @Published public private(set) var lastSavedIdeaID: IdeaID?
    @Published public private(set) var failureMessage: String?
    public private(set) var saveGeneration: UInt64 = 0
    private var successGeneration: UInt64 = 0

    public init() {}

    public var isDirty: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            != originalText
    }

    /// Starts an edit only when no other idea owns the session. Re-entering
    /// the same idea is deliberately idempotent so a repeated double-click
    /// cannot replace a dirty draft with the persisted body.
    @discardableResult
    public func begin(id: IdeaID, body: String) -> Bool {
        if let activeID = ideaID {
            return activeID == id
        }
        ideaID = id
        successGeneration &+= 1
        lastSavedIdeaID = nil
        failureMessage = nil
        originalText = body
        draftText = body
        saveState = .idle
        return true
    }

    public func updateText(_ text: String) {
        guard draftText != text else { return }
        draftText = text
        saveState = .idle
        failureMessage = nil
    }

    @discardableResult
    public func save(
        using persist: (IdeaID, String) -> Bool
    ) -> Bool {
        guard let ideaID else { return false }
        let normalized = draftText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.isEmpty == false else {
            saveState = .empty
            return false
        }
        guard normalized != originalText else {
            finish()
            return true
        }

        saveGeneration &+= 1
        failureMessage = nil
        saveState = .saving
        guard persist(ideaID, normalized) else {
            saveState = .failed
            return false
        }

        finish()
        presentSuccess(for: ideaID)
        return true
    }

    public func cancel() {
        finish()
    }

    public func setFailureMessage(_ message: String) {
        failureMessage = message
    }

    /// Funnels every editor exit through one reasoned boundary. Callers defer
    /// blur by one main-run-loop turn so an explicit cancel intent can win
    /// before AppKit reports the corresponding focus loss.
    @discardableResult
    public func end(
        reason: IdeaInlineEditorEndReason,
        using persist: (IdeaID, String) -> Bool
    ) -> Bool {
        switch reason {
        case .explicitCancel:
            guard ideaID != nil else { return false }
            finish()
            return true
        case .submit, .blur, .navigation:
            return save(using: persist)
        }
    }

    private func finish() {
        successGeneration &+= 1
        ideaID = nil
        originalText = ""
        draftText = ""
        lastSavedIdeaID = nil
        failureMessage = nil
        saveState = .idle
    }

    private func presentSuccess(for id: IdeaID) {
        successGeneration &+= 1
        let generation = successGeneration
        lastSavedIdeaID = id
        saveState = .succeeded
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self,
                  successGeneration == generation,
                  saveState == .succeeded,
                  ideaID == nil
            else { return }
            lastSavedIdeaID = nil
            saveState = .idle
        }
    }
}
