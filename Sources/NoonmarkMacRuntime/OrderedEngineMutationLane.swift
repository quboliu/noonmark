import Dispatch
import Foundation
import NoonmarkCore

/// Serializes engine mutations and their durable commit as one ordered unit.
///
/// The lane owns an immutable committed engine head. Each operation receives a
/// copy-on-write candidate and the exact source snapshot that precedes it. The
/// head advances only after the operation returns successfully, so a failed
/// persistence attempt cannot leak into a later mutation.
public final class OrderedEngineMutationLane: @unchecked Sendable {
    public struct Head: @unchecked Sendable {
        public let sequence: UInt64
        public let engine: NoonmarkEngine
    }

    public struct Commit<Result>: @unchecked Sendable {
        public let sequence: UInt64
        public let engine: NoonmarkEngine
        public let sourceSnapshot: NoonmarkSnapshot
        public let result: Result
        public let sourceSnapshotMilliseconds: Double
        public let cloneMilliseconds: Double
        public let operationMilliseconds: Double
        public let totalMilliseconds: Double

        fileprivate init(
            sequence: UInt64,
            engine: NoonmarkEngine,
            sourceSnapshot: NoonmarkSnapshot,
            result: Result,
            sourceSnapshotMilliseconds: Double,
            cloneMilliseconds: Double,
            operationMilliseconds: Double,
            totalMilliseconds: Double
        ) {
            self.sequence = sequence
            self.engine = engine
            self.sourceSnapshot = sourceSnapshot
            self.result = result
            self.sourceSnapshotMilliseconds =
                sourceSnapshotMilliseconds
            self.cloneMilliseconds = cloneMilliseconds
            self.operationMilliseconds = operationMilliseconds
            self.totalMilliseconds = totalMilliseconds
        }
    }

    public typealias Operation<Result> = @Sendable (
        _ candidate: NoonmarkEngine,
        _ sourceSnapshot: NoonmarkSnapshot
    ) throws -> Result

    private let queue: DispatchQueue
    private var committedEngine: NoonmarkEngine
    private var committedSequence: UInt64 = 0

    public init(
        engine: NoonmarkEngine,
        label: String = "app.noonmark.engine-mutation"
    ) {
        committedEngine = NoonmarkEngine(copying: engine)
        // Autosave must never compete with marked-text handling or AppKit
        // layout for user-initiated CPU time. The durable boundary remains
        // ordered and awaitable, while utility QoS lets live input win.
        queue = DispatchQueue(
            label: label,
            qos: .utility,
            autoreleaseFrequency: .workItem
        )
    }

    public func commit<Result: Sendable>(
        _ operation: @escaping Operation<Result>
    ) async throws -> Commit<Result> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try execute(operation)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func commitAndWait<Result>(
        _ operation: Operation<Result>
    ) throws -> Commit<Result> {
        try queue.sync { [self] in
            try execute(operation)
        }
    }

    /// Replaces the authoritative head after an exclusive import or sync.
    ///
    /// Queue ordering guarantees that already-enqueued commits finish first.
    @discardableResult
    public func replaceAndWait(
        with engine: NoonmarkEngine
    ) -> UInt64 {
        let replacement = NoonmarkEngine(copying: engine)
        return queue.sync { [self] in
            committedEngine = replacement
            committedSequence &+= 1
            return committedSequence
        }
    }

    /// Waits until every operation enqueued before this call has completed.
    public func drain() {
        queue.sync {}
    }

    public func headAndWait() -> Head {
        queue.sync { [self] in
            Head(
                sequence: committedSequence,
                engine: committedEngine
            )
        }
    }

    public func head() async -> Head {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(
                    returning: Head(
                        sequence: committedSequence,
                        engine: committedEngine
                    )
                )
            }
        }
    }

    private func execute<Result>(
        _ operation: Operation<Result>
    ) throws -> Commit<Result> {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sourceSnapshot = committedEngine.snapshot()
        let snapshottedAt =
            ProcessInfo.processInfo.systemUptime
        let candidate = NoonmarkEngine(copying: committedEngine)
        let clonedAt = ProcessInfo.processInfo.systemUptime
        let result = try operation(candidate, sourceSnapshot)
        let operatedAt = ProcessInfo.processInfo.systemUptime
        committedEngine = candidate
        committedSequence &+= 1
        return Commit(
            sequence: committedSequence,
            engine: candidate,
            sourceSnapshot: sourceSnapshot,
            result: result,
            sourceSnapshotMilliseconds:
            (snapshottedAt - startedAt) * 1000,
            cloneMilliseconds:
            (clonedAt - snapshottedAt) * 1000,
            operationMilliseconds:
            (operatedAt - clonedAt) * 1000,
            totalMilliseconds:
            (operatedAt - startedAt) * 1000
        )
    }
}
