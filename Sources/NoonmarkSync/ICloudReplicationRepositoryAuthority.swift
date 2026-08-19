import CryptoKit
import Foundation

public enum ICloudReplicationRepositoryAuthorityError: String,
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

private struct ICloudMarkerSnapshotLoadResult: Sendable {
    let localSnapshot: ICloudMarkerVersionSnapshot
    let nonlocalVersions: [Data]
}

enum ICloudMarkerAuthorityObservationVerdict: Equatable, Sendable {
    case stable
    case revalidatedEquivalent
    case unavailable
    case divergent
}

struct ICloudMarkerAuthorityFinalObservation: Sendable {
    let snapshot: ICloudMarkerVersionSnapshot
    let verdict: ICloudMarkerAuthorityObservationVerdict
}

struct ICloudMarkerAuthorityObservationSession: Sendable {
    let initialSnapshot: ICloudMarkerVersionSnapshot
    let initialVerdict: ICloudMarkerAuthorityObservationVerdict
    let snapshot: @Sendable () async throws -> ICloudMarkerVersionSnapshot
    let finish: @Sendable () throws -> ICloudMarkerAuthorityFinalObservation

    init(
        initialSnapshot: ICloudMarkerVersionSnapshot,
        initialVerdict: ICloudMarkerAuthorityObservationVerdict = .stable,
        snapshot: @escaping @Sendable () async throws
            -> ICloudMarkerVersionSnapshot,
        finish: @escaping @Sendable () throws
            -> ICloudMarkerAuthorityFinalObservation
    ) {
        self.initialSnapshot = initialSnapshot
        self.initialVerdict = initialVerdict
        self.snapshot = snapshot
        self.finish = finish
    }
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
        let snapshot = try locallyAvailableMarkerVersions(at: markerURL)
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
        let expectedMarkerData = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        let observer = ICloudMarkerAuthorityObserver(
            markerURL: markerURL,
            expectedMarkerData: expectedMarkerData,
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
            let finalObservation = try lease.observationSession.finish()
            try validate(finalObservation.snapshot, expected: lease.expected)
            try validate(finalObservation.verdict)
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
            try validate(observationSession.initialVerdict)
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

    static func validate(
        _ verdict: ICloudMarkerAuthorityObservationVerdict
    ) throws {
        switch verdict {
        case .stable, .revalidatedEquivalent:
            return
        case .unavailable:
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        case .divergent:
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
    }

    static func locallyAvailableMarkerVersions(
        at markerURL: URL,
        beforeRead: ((URL) throws -> Void)? = nil
    ) throws -> ICloudMarkerVersionSnapshot {
        var snapshot: ICloudMarkerVersionSnapshot?
        var readFailed = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: markerURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try beforeRead?(coordinatedURL)
                snapshot = try markerVersions(atCoordinatedURL: coordinatedURL)
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
        return snapshot
    }

    static func markerVersions(
        atCoordinatedURL markerURL: URL
    ) throws -> ICloudMarkerVersionSnapshot {
        return ICloudMarkerVersionSnapshot(
            current: try Data(
                contentsOf: markerURL,
                options: [.mappedIfSafe]
            ),
            conflicts: try otherVersionData(at: markerURL)
        )
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

final class ICloudMarkerAuthorityEventAccumulator: @unchecked Sendable {
    private let stateLock = NSLock()
    private let expectedMarkerData: Data
    private var observedVerdict: ICloudMarkerAuthorityObservationVerdict =
        .stable

    init(expectedMarkerData: Data) {
        self.expectedMarkerData = expectedMarkerData
    }

    func recordMarkerData(_ data: Data) {
        stateLock.lock()
        if data != expectedMarkerData {
            observedVerdict = .divergent
        } else if observedVerdict == .stable {
            observedVerdict = .revalidatedEquivalent
        }
        stateLock.unlock()
    }

    func recordObservationUnavailable() {
        stateLock.lock()
        if observedVerdict != .divergent {
            observedVerdict = .unavailable
        }
        stateLock.unlock()
    }

    func verdict() -> ICloudMarkerAuthorityObservationVerdict {
        stateLock.lock()
        defer { stateLock.unlock() }
        return observedVerdict
    }
}

private final class ICloudMarkerVersionPresenter:
    NSObject,
    NSFilePresenter,
    @unchecked Sendable
{
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    let events: ICloudMarkerAuthorityEventAccumulator

    init(markerURL: URL, expectedMarkerData: Data) {
        presentedItemURL = markerURL
        events = ICloudMarkerAuthorityEventAccumulator(
            expectedMarkerData: expectedMarkerData
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        queue.name = "app.noonmark.icloud-marker-version-observer"
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        record(version: version)
    }

    func presentedItemDidLose(_ version: NSFileVersion) {
        record(version: version)
    }

    func presentedItemDidResolveConflict(_ version: NSFileVersion) {
        record(version: version)
    }

    func presentedItemDidChange() {
        recordCurrentMarker()
    }

    func relinquishPresentedItem(
        toWriter writer: @escaping @Sendable (
            (@Sendable () -> Void)?
        ) -> Void
    ) {
        writer { [weak self] in
            self?.recordCurrentMarker()
        }
    }

    private func recordCurrentMarker() {
        guard let markerURL = presentedItemURL else {
            events.recordObservationUnavailable()
            return
        }
        do {
            events.recordMarkerData(
                try Data(
                    contentsOf: markerURL,
                    options: [.mappedIfSafe]
                )
            )
        } catch {
            events.recordObservationUnavailable()
        }
    }

    private func record(version: NSFileVersion) {
        do {
            events.recordMarkerData(
                try Data(
                    contentsOf: version.url,
                    options: [.mappedIfSafe]
                )
            )
        } catch {
            events.recordObservationUnavailable()
        }
    }
}

final class ICloudMarkerAuthorityObserver: @unchecked Sendable {
    private let markerURL: URL
    private let presenter: ICloudMarkerVersionPresenter
    private let nonlocalVersionLoader: ICloudMarkerNonlocalVersionLoader
    private let stateLock = NSLock()
    private var isRegistered = false
    private var isFinished = false

    init(
        markerURL: URL,
        expectedMarkerData: Data,
        nonlocalVersionLoader: @escaping ICloudMarkerNonlocalVersionLoader
    ) {
        self.markerURL = markerURL
        presenter = ICloudMarkerVersionPresenter(
            markerURL: markerURL,
            expectedMarkerData: expectedMarkerData
        )
        self.nonlocalVersionLoader = nonlocalVersionLoader
    }

    func beginObservation() async throws
        -> ICloudMarkerAuthorityObservationSession
    {
        do {
            let initialSnapshot = try await snapshot(
                registeringPresenter: true
            )
            let initialVerdict = observedAuthorityVerdict()
            return ICloudMarkerAuthorityObservationSession(
                initialSnapshot: initialSnapshot,
                initialVerdict: initialVerdict,
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
        let initial = try await coordinatedSnapshotStartingNonlocalLoad(
            registeringPresenter: registeringPresenter
        )
        let finalLocalSnapshot = try coordinatedLocalSnapshot(
            registeringPresenter: false
        )
        guard initial.localSnapshot.current == finalLocalSnapshot.current
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
        return ICloudMarkerVersionSnapshot(
            current: finalLocalSnapshot.current,
            conflicts: initial.localSnapshot.conflicts
                + finalLocalSnapshot.conflicts
                + initial.nonlocalVersions
        )
    }

    private func coordinatedSnapshotStartingNonlocalLoad(
        registeringPresenter: Bool
    ) async throws -> ICloudMarkerSnapshotLoadResult {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ICloudMarkerSnapshotLoadCompletion(
                continuation: continuation
            )
            do {
                let localSnapshot = try coordinatedLocalSnapshot(
                    registeringPresenter: registeringPresenter,
                    beforeRead: { coordinatedURL in
                        self.startNonlocalVersionLoad(
                            at: coordinatedURL,
                            completion: completion.recordNonlocal
                        )
                    }
                )
                completion.recordLocal(.success(localSnapshot))
            } catch {
                completion.recordLocal(.failure(error))
            }
        }
    }

    private func coordinatedLocalSnapshot(
        registeringPresenter: Bool,
        beforeRead: ((URL) -> Void)? = nil
    ) throws -> ICloudMarkerVersionSnapshot {
        try ensureObservationIsActive()
        return try ICloudReplicationRepositoryAuthority
            .locallyAvailableMarkerVersions(
                at: markerURL,
                beforeRead: { coordinatedURL in
                    if registeringPresenter {
                        try self.registerPresenterInsideCoordinatedRead()
                    }
                    beforeRead?(coordinatedURL)
                }
            )
    }

    private func startNonlocalVersionLoad(
        at url: URL,
        completion: @escaping @Sendable (
            ICloudMarkerNonlocalVersionResult
        ) -> Void
    ) {
        nonlocalVersionLoader(url, completion)
    }

    private func ensureObservationIsActive() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isFinished == false else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
    }

    private func observedAuthorityVerdict()
        -> ICloudMarkerAuthorityObservationVerdict
    {
        presenter.presentedItemOperationQueue.waitUntilAllOperationsAreFinished()
        return presenter.events.verdict()
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

    private func finishObservation() throws
        -> ICloudMarkerAuthorityFinalObservation
    {
        stateLock.lock()
        if isFinished {
            stateLock.unlock()
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        isFinished = true
        let mustRemovePresenter = isRegistered
        isRegistered = false
        stateLock.unlock()

        guard mustRemovePresenter else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        let removalState = ICloudMarkerPresenterRemovalState()
        var finalSnapshot: ICloudMarkerVersionSnapshot?
        var finalReadFailed = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: markerURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                finalSnapshot = try ICloudReplicationRepositoryAuthority
                    .markerVersions(atCoordinatedURL: coordinatedURL)
            } catch {
                finalReadFailed = true
            }
            NSFileCoordinator.removeFilePresenter(self.presenter)
            removalState.markRemoved()
        }
        if removalState.didRemove == false {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter.presentedItemOperationQueue.waitUntilAllOperationsAreFinished()
        guard coordinationError == nil,
              finalReadFailed == false,
              removalState.didRemove,
              let finalSnapshot
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        return ICloudMarkerAuthorityFinalObservation(
            snapshot: finalSnapshot,
            verdict: presenter.events.verdict()
        )
    }
}

private final class ICloudMarkerSnapshotLoadCompletion: @unchecked Sendable {
    private let stateLock = NSLock()
    private var continuation:
        CheckedContinuation<ICloudMarkerSnapshotLoadResult, any Error>?
    private var localResult:
        Result<ICloudMarkerVersionSnapshot, any Error>?
    private var nonlocalResult: ICloudMarkerNonlocalVersionResult?

    init(
        continuation: CheckedContinuation<
            ICloudMarkerSnapshotLoadResult,
            any Error
        >
    ) {
        self.continuation = continuation
    }

    func recordLocal(
        _ result: Result<ICloudMarkerVersionSnapshot, any Error>
    ) {
        let resume = stateLock.withLock {
            localResult = result
            return takeResumeActionIfReady()
        }
        resume?()
    }

    func recordNonlocal(_ result: ICloudMarkerNonlocalVersionResult) {
        let resume = stateLock.withLock {
            nonlocalResult = result
            return takeResumeActionIfReady()
        }
        resume?()
    }

    private func takeResumeActionIfReady() -> (() -> Void)? {
        guard let continuation else { return nil }
        switch localResult {
        case let .failure(error):
            self.continuation = nil
            return { continuation.resume(throwing: error) }
        case let .success(localSnapshot):
            guard let nonlocalResult else { return nil }
            self.continuation = nil
            switch nonlocalResult {
            case let .success(versions):
                let result = ICloudMarkerSnapshotLoadResult(
                    localSnapshot: localSnapshot,
                    nonlocalVersions: versions
                )
                return { continuation.resume(returning: result) }
            case .unavailable:
                return {
                    continuation.resume(
                        throwing: ICloudReplicationRepositoryAuthorityError
                            .unavailableMarkerVersion
                    )
                }
            }
        case nil:
            return nil
        }
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
