import Foundation

/// Owns one local-first sync run so callers can stop and await it without
/// leaking an unstructured task. Persistence and result installation stay at
/// the caller's existing ordered engine-write seam.
@MainActor
public final class LocalFirstSyncRunController<Output: Sendable> {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case stopping
    }

    public private(set) var state = State.idle

    private var activeRunID: UUID?
    private var activeTask: Task<Void, Never>?

    public init() {}

    deinit {
        activeTask?.cancel()
    }

    @discardableResult
    public func start(
        operation: @escaping @Sendable () async throws -> Output,
        completion: @escaping @MainActor (
            Result<Output, any Error>
        ) -> Void
    ) -> Bool {
        guard activeTask == nil else { return false }
        let runID = UUID()
        activeRunID = runID
        state = .running
        activeTask = Task { [weak self] in
            let result: Result<Output, any Error>
            do {
                result = await .success(try operation())
            } catch {
                result = .failure(error)
            }
            self?.complete(
                runID: runID,
                result: result,
                completion: completion
            )
        }
        return true
    }

    public func stop() async {
        guard let activeTask else { return }
        state = .stopping
        activeTask.cancel()
        await activeTask.value
    }

    private func complete(
        runID: UUID,
        result: Result<Output, any Error>,
        completion: @escaping @MainActor (
            Result<Output, any Error>
        ) -> Void
    ) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        activeTask = nil
        state = .idle
        completion(result)
    }
}
