import CryptoKit
import Foundation

enum ICloudReplicationRepositoryAuthorityError:
    Error,
    Equatable,
    Sendable
{
    case invalidRepositoryScope
    case invalidMarkerVersion
    case divergentMarkerVersion
    case unavailableMarkerVersion
    case existingAuthorityMarkerUnavailable
}

struct ICloudMarkerVersionSnapshot: Sendable {
    let current: Data
    let conflicts: [Data]
}

struct ICloudMarkerAuthorityObservationSession: Sendable {
    let initialSnapshot: ICloudMarkerVersionSnapshot
    let snapshot: @Sendable () async throws -> ICloudMarkerVersionSnapshot
    let finish: @Sendable () throws -> Bool
}

struct ICloudMarkerAuthorityValidationLease: Sendable {
    let expected: ReplicationRepositoryDescriptor
    let observationSession: ICloudMarkerAuthorityObservationSession
}

enum ICloudMarkerNonlocalVersionResult: Sendable {
    case success([Data])
    case unavailable
}

typealias ICloudMarkerNonlocalVersionLoader = @Sendable (
    URL,
    @escaping @Sendable (ICloudMarkerNonlocalVersionResult) -> Void
) -> Void

enum ICloudReplicationRepositoryAuthority {
    private static let generationDomain =
        "app.noonmark.replication-v2.repository-generation\u{0}"

    static func generationID(for repositoryScope: String) throws -> UUID {
        try validateRepositoryScope(repositoryScope)
        var bytes = Array(
            SHA256.hash(
                data: Data((generationDomain + repositoryScope).utf8)
            ).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func openRepository(
        at rootURL: URL,
        scope repositoryScope: String,
        existingGenerationID: UUID?
    ) throws -> ReplicationRepositoryOpenResult {
        let derivedGenerationID = try generationID(for: repositoryScope)
        if let existingGenerationID,
           existingGenerationID != derivedGenerationID
        {
            let result: ReplicationRepositoryOpenResult
            do {
                result = try FileReplicationRepositoryBootstrap
                    .openExistingWithStatus(at: rootURL)
            } catch ReplicationRepositoryBootstrapError
                .markerUnavailableForExistingAuthority
            {
                throw ICloudReplicationRepositoryAuthorityError
                    .existingAuthorityMarkerUnavailable
            }
            guard result.descriptor.generationID == existingGenerationID else {
                throw ICloudReplicationRepositoryAuthorityError
                    .divergentMarkerVersion
            }
            return result
        }
        let result = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: rootURL,
                generationID: { derivedGenerationID }
            )
        guard result.descriptor.generationID == derivedGenerationID else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
        return result
    }

    static func validateMarkerVersions(
        current: Data,
        conflicts: [Data]
    ) throws {
        try validateCanonicalMarker(current)
        for conflict in conflicts {
            try validateCanonicalMarker(conflict)
            guard conflict == current else {
                throw ICloudReplicationRepositoryAuthorityError
                    .divergentMarkerVersion
            }
        }
    }

    static func validateLocallyAvailableMarkerVersions(
        at markerURL: URL,
        expected descriptor: ReplicationRepositoryDescriptor
    ) throws {
        var snapshot: ICloudMarkerVersionSnapshot?
        var readFailed = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: markerURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let versions =
                    (NSFileVersion.otherVersionsOfItem(
                        at: coordinatedURL
                    ) ?? [])
                    + (NSFileVersion.unresolvedConflictVersionsOfItem(
                        at: coordinatedURL
                    ) ?? [])
                snapshot = ICloudMarkerVersionSnapshot(
                    current: try Data(
                        contentsOf: coordinatedURL,
                        options: [.mappedIfSafe]
                    ),
                    conflicts: try versions.map {
                        try Data(
                            contentsOf: $0.url,
                            options: [.mappedIfSafe]
                        )
                    }
                )
            } catch {
                readFailed = true
            }
        }
        guard coordinationError == nil,
              readFailed == false,
              let snapshot
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        try validate(snapshot, expected: descriptor)
    }

    static func withValidatedMarkerAuthority<Result: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        at markerURL: URL,
        expected descriptor: ReplicationRepositoryDescriptor,
        nonlocalVersionLoader: @escaping ICloudMarkerNonlocalVersionLoader
            = loadNonlocalVersionData,
        operation: () async throws -> Result
    ) async throws -> Result {
        let lease = try await beginValidatedMarkerAuthority(
            at: markerURL,
            expected: descriptor,
            nonlocalVersionLoader: nonlocalVersionLoader
        )
        return try await executeRequiringPostValidation(
            isolation: isolation,
            operation: operation,
            postValidation: {
                try await finishValidatedMarkerAuthority(lease)
            }
        )
    }

    static func withValidatedMarkerAuthority<Result: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        expected descriptor: ReplicationRepositoryDescriptor,
        observationSession: ICloudMarkerAuthorityObservationSession,
        operation: () async throws -> Result
    ) async throws -> Result {
        let lease = try beginValidatedMarkerAuthority(
            expected: descriptor,
            observationSession: observationSession
        )
        return try await executeRequiringPostValidation(
            isolation: isolation,
            operation: operation,
            postValidation: {
                try await finishValidatedMarkerAuthority(lease)
            }
        )
    }

    static func executeRequiringPostValidation<Result: Sendable>(
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result,
        postValidation: () async throws -> Void
    ) async throws -> Result {
        let result: Result
        do {
            result = try await operation()
        } catch {
            let operationError = error
            try await postValidation()
            throw operationError
        }
        try await postValidation()
        return result
    }

    static func beginValidatedMarkerAuthority(
        at markerURL: URL,
        expected descriptor: ReplicationRepositoryDescriptor,
        nonlocalVersionLoader: @escaping ICloudMarkerNonlocalVersionLoader
            = loadNonlocalVersionData
    ) async throws -> ICloudMarkerAuthorityValidationLease {
        let observer = ICloudMarkerAuthorityObserver(
            markerURL: markerURL,
            nonlocalVersionLoader: nonlocalVersionLoader
        )
        let session = try await observer.beginObservation()
        return try beginValidatedMarkerAuthority(
            expected: descriptor,
            observationSession: session
        )
    }

    static func finishValidatedMarkerAuthority(
        _ lease: ICloudMarkerAuthorityValidationLease
    ) async throws {
        do {
            let finalSnapshot = try await lease.observationSession.snapshot()
            try validate(finalSnapshot, expected: lease.expected)
            let authorityChanged = try lease.observationSession.finish()
            guard authorityChanged == false else {
                throw ICloudReplicationRepositoryAuthorityError
                    .divergentMarkerVersion
            }
        } catch {
            cancelValidatedMarkerAuthority(lease)
            throw error
        }
    }

    static func cancelValidatedMarkerAuthority(
        _ lease: ICloudMarkerAuthorityValidationLease
    ) {
        _ = try? lease.observationSession.finish()
    }
}

private extension ICloudReplicationRepositoryAuthority {
    static func validateRepositoryScope(_ repositoryScope: String) throws {
        guard repositoryScope.isEmpty == false,
              repositoryScope.utf8.contains(0) == false
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidRepositoryScope
        }
    }

    static func validateCanonicalMarker(_ data: Data) throws {
        let descriptor: ReplicationRepositoryDescriptor
        do {
            descriptor = try ReplicationPublicationBuilder
                .canonicalDecoder().decode(
                    ReplicationRepositoryDescriptor.self,
                    from: data
                )
        } catch {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidMarkerVersion
        }
        let canonical = try? ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        guard descriptor.formatVersion
            == FileReplicationRepositoryBootstrap.formatVersion,
            canonical == data
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidMarkerVersion
        }
    }

    static func validate(
        _ snapshot: ICloudMarkerVersionSnapshot,
        expected descriptor: ReplicationRepositoryDescriptor
    ) throws {
        try validateMarkerVersions(
            current: snapshot.current,
            conflicts: snapshot.conflicts
        )
        let expected = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        guard snapshot.current == expected else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
    }

    static func beginValidatedMarkerAuthority(
        expected descriptor: ReplicationRepositoryDescriptor,
        observationSession: ICloudMarkerAuthorityObservationSession
    ) throws -> ICloudMarkerAuthorityValidationLease {
        do {
            try validate(
                observationSession.initialSnapshot,
                expected: descriptor
            )
            return ICloudMarkerAuthorityValidationLease(
                expected: descriptor,
                observationSession: observationSession
            )
        } catch {
            _ = try? observationSession.finish()
            throw error
        }
    }

    static func otherVersionData(at markerURL: URL) throws -> [Data] {
        let versions = (NSFileVersion.otherVersionsOfItem(at: markerURL) ?? [])
            + (NSFileVersion.unresolvedConflictVersionsOfItem(
                at: markerURL
            ) ?? [])
        return try versions.map { version in
            try coordinatedData(at: version.url)
        }
    }

    static func coordinatedData(at url: URL) throws -> Data {
        var result: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }
        if coordinationError != nil || readError != nil {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        guard let result else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        return result
    }

    static func loadNonlocalVersionData(
        at url: URL,
        completion: @escaping @Sendable (
            ICloudMarkerNonlocalVersionResult
        ) -> Void
    ) {
        NSFileVersion.getNonlocalVersionsOfItem(at: url) { versions, error in
            guard error == nil else {
                completion(.unavailable)
                return
            }
            do {
                completion(
                    .success(
                        try (versions ?? []).map {
                            try coordinatedData(at: $0.url)
                        }
                    )
                )
            } catch {
                completion(.unavailable)
            }
        }
    }
}

private final class ICloudMarkerVersionPresenter:
    NSObject,
    NSFilePresenter,
    @unchecked Sendable
{
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    private let stateLock = NSLock()
    private var authorityChanged = false

    init(markerURL: URL) {
        presentedItemURL = markerURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        queue.name = "app.noonmark.icloud-marker-version-observer"
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidGain(_: NSFileVersion) {
        recordAuthorityChange()
    }

    func presentedItemDidLose(_: NSFileVersion) {
        recordAuthorityChange()
    }

    func presentedItemDidChange() {
        recordAuthorityChange()
    }

    func didObserveAuthorityChange() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authorityChanged
    }

    private func recordAuthorityChange() {
        stateLock.lock()
        authorityChanged = true
        stateLock.unlock()
    }
}

private final class ICloudMarkerAuthorityObserver: @unchecked Sendable {
    private let markerURL: URL
    private let presenter: ICloudMarkerVersionPresenter
    private let nonlocalVersionLoader: ICloudMarkerNonlocalVersionLoader
    private let stateLock = NSLock()
    private var isRegistered = false
    private var isFinished = false

    init(
        markerURL: URL,
        nonlocalVersionLoader: @escaping ICloudMarkerNonlocalVersionLoader
    ) {
        self.markerURL = markerURL
        presenter = ICloudMarkerVersionPresenter(markerURL: markerURL)
        self.nonlocalVersionLoader = nonlocalVersionLoader
    }

    func beginObservation() async throws
        -> ICloudMarkerAuthorityObservationSession
    {
        do {
            let initialSnapshot = try await snapshot(
                registeringPresenter: true
            )
            return ICloudMarkerAuthorityObservationSession(
                initialSnapshot: initialSnapshot,
                snapshot: { [self] in
                    try await snapshot(registeringPresenter: false)
                },
                finish: { [self] in
                    try finishObservation()
                }
            )
        } catch {
            _ = try? finishObservation()
            throw error
        }
    }

    private func snapshot(
        registeringPresenter: Bool
    ) async throws -> ICloudMarkerVersionSnapshot {
        try ensureObservationIsActive()
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ICloudMarkerSnapshotCompletion(
                continuation: continuation
            )
            let coordinationState = ICloudMarkerSnapshotCoordinationState()
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(
                readingItemAt: markerURL,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    if registeringPresenter {
                        try self.registerPresenterInsideCoordinatedRead()
                    }
                    let current = try Data(
                        contentsOf: coordinatedURL,
                        options: [.mappedIfSafe]
                    )
                    let localVersions = try ICloudReplicationRepositoryAuthority
                        .otherVersionData(at: coordinatedURL)
                    coordinationState.markNonlocalRequestStarted()
                    nonlocalVersionLoader(coordinatedURL) { result in
                        switch result {
                        case let .success(nonlocalVersions):
                            completion.resume(
                                returning: ICloudMarkerVersionSnapshot(
                                    current: current,
                                    conflicts: localVersions + nonlocalVersions
                                )
                            )
                        case .unavailable:
                            completion.resume(
                                throwing: ICloudReplicationRepositoryAuthorityError
                                    .unavailableMarkerVersion
                            )
                        }
                    }
                } catch {
                    coordinationState.recordSetupFailure()
                }
            }
            if coordinationError != nil
                || coordinationState.didFailSetup
                || coordinationState.didStartNonlocalRequest == false
            {
                completion.resume(
                    throwing: ICloudReplicationRepositoryAuthorityError
                        .unavailableMarkerVersion
                )
            }
        }
    }

    private func ensureObservationIsActive() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isFinished == false else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
    }

    private func registerPresenterInsideCoordinatedRead() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isFinished == false else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        guard isRegistered == false else { return }
        NSFileCoordinator.addFilePresenter(presenter)
        isRegistered = true
    }

    private func finishObservation() throws -> Bool {
        stateLock.lock()
        if isFinished {
            stateLock.unlock()
            presenter.presentedItemOperationQueue
                .waitUntilAllOperationsAreFinished()
            return presenter.didObserveAuthorityChange()
        }
        isFinished = true
        let mustRemovePresenter = isRegistered
        isRegistered = false
        stateLock.unlock()

        guard mustRemovePresenter else {
            return presenter.didObserveAuthorityChange()
        }
        let removalState = ICloudMarkerPresenterRemovalState()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: markerURL,
            options: [],
            error: &coordinationError
        ) { _ in
            NSFileCoordinator.removeFilePresenter(self.presenter)
            removalState.markRemoved()
        }
        if removalState.didRemove == false {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter.presentedItemOperationQueue.waitUntilAllOperationsAreFinished()
        guard coordinationError == nil, removalState.didRemove else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        return presenter.didObserveAuthorityChange()
    }
}

private final class ICloudMarkerSnapshotCompletion: @unchecked Sendable {
    private let stateLock = NSLock()
    private var continuation:
        CheckedContinuation<ICloudMarkerVersionSnapshot, any Error>?

    init(
        continuation: CheckedContinuation<
            ICloudMarkerVersionSnapshot,
            any Error
        >
    ) {
        self.continuation = continuation
    }

    func resume(returning snapshot: ICloudMarkerVersionSnapshot) {
        takeContinuation()?.resume(returning: snapshot)
    }

    func resume(throwing error: any Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation()
        -> CheckedContinuation<ICloudMarkerVersionSnapshot, any Error>?
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        let result = continuation
        continuation = nil
        return result
    }
}

private final class ICloudMarkerSnapshotCoordinationState:
    @unchecked Sendable
{
    private let stateLock = NSLock()
    private var nonlocalRequestStarted = false
    private var setupFailed = false

    var didStartNonlocalRequest: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nonlocalRequestStarted
    }

    var didFailSetup: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return setupFailed
    }

    func markNonlocalRequestStarted() {
        stateLock.lock()
        nonlocalRequestStarted = true
        stateLock.unlock()
    }

    func recordSetupFailure() {
        stateLock.lock()
        setupFailed = true
        stateLock.unlock()
    }
}

private final class ICloudMarkerPresenterRemovalState: @unchecked Sendable {
    private let stateLock = NSLock()
    private var removed = false

    var didRemove: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return removed
    }

    func markRemoved() {
        stateLock.lock()
        removed = true
        stateLock.unlock()
    }
}
