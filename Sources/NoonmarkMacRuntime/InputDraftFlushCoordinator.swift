import Foundation

/// Owns the lifecycle boundary for user-editable drafts that otherwise live
/// inside SwiftUI view state.
///
/// A registered handler must return only after its newest visible value is
/// durable. Termination is allowed only when every live handler succeeds.
@MainActor
public final class InputDraftFlushCoordinator {
    public typealias Handler = @MainActor () async -> Bool

    private struct Registration {
        let token: UUID
        let handler: Handler
    }

    private var registrations: [String: Registration] = [:]

    public private(set) var lastFailedOwnerIDs: [String] = []

    public init() {}

    public func register(
        ownerID: String,
        token: UUID,
        handler: @escaping Handler
    ) {
        precondition(ownerID.isEmpty == false)
        registrations[ownerID] = Registration(
            token: token,
            handler: handler
        )
    }

    public func unregister(
        ownerID: String,
        token: UUID
    ) {
        guard registrations[ownerID]?.token == token else {
            return
        }
        registrations[ownerID] = nil
    }

    /// Flushes a stable snapshot so handlers can safely register or unregister
    /// while another handler is suspended.
    @discardableResult
    public func flushAll() async -> Bool {
        let snapshot = registrations
            .sorted { $0.key < $1.key }
        var failedOwnerIDs: [String] = []
        for (ownerID, registration) in snapshot {
            if await registration.handler() == false {
                failedOwnerIDs.append(ownerID)
            }
        }
        lastFailedOwnerIDs = failedOwnerIDs
        return failedOwnerIDs.isEmpty
    }

    public var registeredOwnerIDs: [String] {
        registrations.keys.sorted()
    }
}
