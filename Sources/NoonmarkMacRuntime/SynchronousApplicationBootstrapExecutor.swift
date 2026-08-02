import Foundation

/// Bridges asynchronous startup preparation into a synchronous AppKit entry
/// point before `NSApplication.run()` owns the main thread.
///
/// The operation must not depend on `MainActor`: the caller intentionally
/// keeps the main thread outside Swift concurrency until preparation finishes.
package enum SynchronousApplicationBootstrapExecutor {
    package static func run<Success: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> Success
    ) throws -> Success {
        precondition(
            Thread.isMainThread,
            "Application bootstrap must be joined by the main entry thread."
        )

        let state = SynchronousApplicationBootstrapState<Success>()
        Task.detached(priority: priority) {
            do {
                let prepared = try await operation()
                state.publish(.success(prepared))
            } catch {
                state.publish(.failure(error))
            }
        }
        return try state.wait()
    }
}

private final class SynchronousApplicationBootstrapState<Success: Sendable>:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var result: Result<Success, any Error>?

    func publish(_ result: Result<Success, any Error>) {
        condition.lock()
        precondition(self.result == nil, "Application bootstrap completed twice.")
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait() throws -> Success {
        condition.lock()
        while result == nil {
            condition.wait()
        }
        let completedResult = result
        condition.unlock()

        guard let completedResult else {
            preconditionFailure("Application bootstrap completed without a result.")
        }
        return try completedResult.get()
    }
}
