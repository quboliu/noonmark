public struct IMETextDraftAutosaveGate: Equatable, Sendable {
    public struct Schedule: Equatable, Hashable, Sendable {
        public let ownerID: String
        public let generation: UInt64
        public let revision: UInt64
        public let sequence: UInt64
        public let delayMilliseconds: UInt64
    }

    public struct PersistenceRequest: Equatable, Sendable {
        public let ownerID: String
        public let generation: UInt64
        public let revision: UInt64
        public let requestID: UInt64

        public init(
            ownerID: String,
            generation: UInt64,
            revision: UInt64,
            requestID: UInt64
        ) {
            self.ownerID = ownerID
            self.generation = generation
            self.revision = revision
            self.requestID = requestID
        }
    }

    public let ownerID: String
    public private(set) var generation: UInt64
    public private(set) var isComposing = false

    public var hasUnflushedChanges: Bool {
        acknowledgedRevision != revision
    }

    public var hasPersistenceInFlight: Bool {
        inFlight != nil
    }

    private var revision: UInt64 = 0
    private var acknowledgedRevision: UInt64 = 0
    private var scheduleSequence: UInt64 = 0
    private var requestSequence: UInt64 = 0
    private var inFlight: PersistenceRequest?
    private var explicitFlushPending = false
    private var retryAttempt: UInt64 = 0

    public init(
        ownerID: String,
        generation: UInt64 = 1
    ) {
        precondition(ownerID.isEmpty == false)
        precondition(generation > 0)
        self.ownerID = ownerID
        self.generation = generation
    }

    @discardableResult
    public mutating func draftDidChange() -> Schedule? {
        nativeSnapshotDidChange(
            textChanged: true,
            isComposing: isComposing
        )
    }

    @discardableResult
    public mutating func compositionDidChange(
        isActive: Bool
    ) -> Schedule? {
        nativeSnapshotDidChange(
            textChanged: false,
            isComposing: isActive
        )
    }

    @discardableResult
    public mutating func nativeSnapshotDidChange(
        textChanged: Bool,
        isComposing nextCompositionState: Bool
    ) -> Schedule? {
        let compositionChanged =
            isComposing != nextCompositionState
        guard textChanged || compositionChanged else {
            return nil
        }
        if textChanged {
            revision &+= 1
            retryAttempt = 0
        }
        isComposing = nextCompositionState
        invalidateSchedule()
        guard isComposing == false,
              hasUnflushedChanges
        else {
            return nil
        }
        return makeSchedule(
            delayMilliseconds: explicitFlushPending ? 0 : 700
        )
    }

    @discardableResult
    public mutating func requestFlush() -> Schedule? {
        explicitFlushPending = true
        guard isComposing == false,
              hasUnflushedChanges,
              inFlight == nil
        else {
            return nil
        }
        return makeSchedule(delayMilliseconds: 0)
    }

    public func permitsAutosave(_ schedule: Schedule?) -> Bool {
        guard let schedule else {
            return false
        }
        return schedule.ownerID == ownerID
            && schedule.generation == generation
            && schedule.revision == revision
            && schedule.sequence == scheduleSequence
            && isComposing == false
            && hasUnflushedChanges
            && inFlight == nil
    }

    public mutating func beginPersistence(
        for schedule: Schedule
    ) -> PersistenceRequest? {
        guard permitsAutosave(schedule) else {
            return nil
        }
        requestSequence &+= 1
        let request = PersistenceRequest(
            ownerID: ownerID,
            generation: generation,
            revision: revision,
            requestID: requestSequence
        )
        inFlight = request
        return request
    }

    @discardableResult
    public mutating func persistenceDidSucceed(
        _ request: PersistenceRequest
    ) -> Schedule? {
        guard request == inFlight,
              request.ownerID == ownerID,
              request.generation == generation
        else {
            return nil
        }
        inFlight = nil
        acknowledgedRevision = max(
            acknowledgedRevision,
            request.revision
        )
        retryAttempt = 0
        guard hasUnflushedChanges else {
            explicitFlushPending = false
            invalidateSchedule()
            return nil
        }
        return makeSchedule(
            delayMilliseconds: explicitFlushPending ? 0 : 700
        )
    }

    @discardableResult
    public mutating func persistenceDidFail(
        _ request: PersistenceRequest
    ) -> Schedule? {
        guard request == inFlight,
              request.ownerID == ownerID,
              request.generation == generation
        else {
            return nil
        }
        inFlight = nil
        retryAttempt &+= 1
        guard isComposing == false,
              hasUnflushedChanges
        else {
            return nil
        }
        let exponent = min(retryAttempt - 1, 4)
        return makeSchedule(
            delayMilliseconds: min(10000, 1000 << exponent)
        )
    }

    public mutating func acknowledgeWithoutPersistence() {
        acknowledgedRevision = revision
        explicitFlushPending = false
        retryAttempt = 0
        inFlight = nil
        invalidateSchedule()
    }

    public mutating func discardLocalChanges() {
        generation &+= 1
        revision = 0
        acknowledgedRevision = 0
        explicitFlushPending = false
        retryAttempt = 0
        isComposing = false
        inFlight = nil
        invalidateSchedule()
    }

    private mutating func makeSchedule(
        delayMilliseconds: UInt64
    ) -> Schedule {
        scheduleSequence &+= 1
        return Schedule(
            ownerID: ownerID,
            generation: generation,
            revision: revision,
            sequence: scheduleSequence,
            delayMilliseconds: delayMilliseconds
        )
    }

    private mutating func invalidateSchedule() {
        scheduleSequence &+= 1
    }
}
