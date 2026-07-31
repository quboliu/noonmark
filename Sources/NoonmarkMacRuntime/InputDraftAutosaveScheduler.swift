@MainActor
public final class InputDraftAutosaveScheduler {
    public typealias Delay =
        @MainActor (UInt64) async throws -> Void
    public typealias Action =
        @MainActor (IMETextDraftAutosaveGate.Schedule) async -> Void

    private let delay: Delay
    private var replacementSequence: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    public convenience init() {
        self.init { delayMilliseconds in
            try await Task.sleep(
                for: .milliseconds(delayMilliseconds)
            )
        }
    }

    public init(delay: @escaping Delay) {
        self.delay = delay
    }

    public func replace(
        with schedule: IMETextDraftAutosaveGate.Schedule?,
        action: @escaping Action
    ) {
        replacementSequence &+= 1
        let expectedSequence = replacementSequence
        pendingTask?.cancel()
        guard let schedule else {
            pendingTask = nil
            return
        }
        let delay = delay
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await delay(schedule.delayMilliseconds)
            } catch {
                return
            }
            guard let self,
                  Task.isCancelled == false,
                  replacementSequence == expectedSequence
            else {
                return
            }
            await action(schedule)
            if replacementSequence == expectedSequence {
                pendingTask = nil
            }
        }
    }

    public func cancel() {
        replacementSequence &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }
}
