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

    private let repository: any IdeaComposerDraftStoring

    public init(repository: any IdeaComposerDraftStoring) {
        self.repository = repository
        text = repository.load()
    }

    public func updateText(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        submissionState = .idle
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

        submissionState = .saving
        guard capture(normalized) else {
            submissionState = .failed
            return false
        }

        text = ""
        repository.save("")
        submissionState = .idle
        return true
    }

    public func dismiss() {
        repository.save(text)
    }

    public func clear() {
        text = ""
        submissionState = .idle
        repository.save("")
    }
}

public enum IdeaInlineEditorSaveState: Equatable, Sendable {
    case idle
    case saving
    case empty
    case failed
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
    public private(set) var saveGeneration: UInt64 = 0

    public init() {}

    public func begin(id: IdeaID, body: String) {
        ideaID = id
        originalText = body
        draftText = body
        saveState = .idle
    }

    public func updateText(_ text: String) {
        guard draftText != text else { return }
        draftText = text
        saveState = .idle
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
        saveState = .saving
        guard persist(ideaID, normalized) else {
            saveState = .failed
            return false
        }

        finish()
        return true
    }

    public func cancel() {
        finish()
    }

    private func finish() {
        ideaID = nil
        originalText = ""
        draftText = ""
        saveState = .idle
    }
}
