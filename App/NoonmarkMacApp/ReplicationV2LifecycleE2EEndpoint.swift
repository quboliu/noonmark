import Foundation
import NoonmarkSync

enum ReplicationV2LifecycleE2EError: Error {
    case injectedReadFailure
}

/// A signed-E2E-only wrapper around the real V2 endpoint. It preserves the
/// endpoint protocol while exposing deterministic failure and cancel/join
/// boundaries to the Preferences WindowServer scenario.
actor ReplicationV2LifecycleE2EEndpoint: ReplicationEndpoint {
    nonisolated let namespace: String

    private let underlying: any ReplicationEndpoint
    private var failNextRead = false
    private var blockNextRead = false
    private var blockingReadActive = false
    private var cancelStarted = false
    private var joinReleased = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    init(underlying: any ReplicationEndpoint) {
        self.underlying = underlying
        namespace = underlying.namespace
    }

    func armReadFailure() -> Bool {
        guard failNextRead == false,
              blockNextRead == false,
              blockingReadActive == false
        else { return false }
        failNextRead = true
        return true
    }

    func armBlockingRead() -> Bool {
        guard failNextRead == false,
              blockNextRead == false,
              blockingReadActive == false,
              readContinuation == nil,
              joinContinuation == nil
        else { return false }
        blockNextRead = true
        cancelStarted = false
        joinReleased = false
        return true
    }

    func waitUntilReadBlocked() async {
        guard blockingReadActive == false else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
        }
    }

    func waitUntilCancelStarted() async {
        guard cancelStarted == false else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    func isReadBlocked() -> Bool {
        blockingReadActive
    }

    func hasCancelStarted() -> Bool {
        cancelStarted
    }

    func releaseJoin() {
        joinReleased = true
        joinContinuation?.resume()
        joinContinuation = nil
    }

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        try await underlying.publish(sealed: publication)
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        try await underlying.observe(pending: receipts)
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        if failNextRead {
            failNextRead = false
            throw ReplicationV2LifecycleE2EError.injectedReadFailure
        }
        guard blockNextRead else {
            return try await underlying.read(after: cursor, budget: budget)
        }
        blockNextRead = false
        blockingReadActive = true
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
        await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
        blockingReadActive = false
        try Task.checkCancellation()
        return try await underlying.read(after: cursor, budget: budget)
    }

    func cancelAndJoin() async {
        if blockingReadActive || readContinuation != nil {
            cancelStarted = true
            cancelWaiters.forEach { $0.resume() }
            cancelWaiters.removeAll()
            readContinuation?.resume()
            readContinuation = nil
            if joinReleased == false {
                await withCheckedContinuation { continuation in
                    joinContinuation = continuation
                }
            }
        }
        await underlying.cancelAndJoin()
    }
}
