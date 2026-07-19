import Darwin
import Foundation

public enum ZhulongJournalMutationOperation: String, Equatable, Sendable {
    case prepare
    case clear
}

public enum ZhulongApplicationJournalMutationPhase: String, Sendable {
    case temporaryOpen
    case temporaryPermissions
    case temporaryWrite
    case temporaryFullSync
    case temporaryFileSync
    case temporaryClose
    case replacement
    case removal
    case directoryOpen
    case directorySync
    case directoryClose
    case observation
    case authentication
    case temporaryCleanup
    case complete
}

public enum ZhulongApplicationJournalCommitOutcome: Equatable, Sendable {
    case committed
    case recoveredCommitted(after: ZhulongApplicationJournalMutationPhase)
}

public enum ZhulongJournalFailureDisposition: Equatable, Sendable {
    case notCommitted
    case unresolved
}

public struct ZhulongApplicationJournalMutationFailure: Error {
    public let operation: ZhulongJournalMutationOperation
    public let disposition:
        ZhulongJournalFailureDisposition
    public let failedPhase: ZhulongApplicationJournalMutationPhase
    public let underlyingError: any Error
    public let durabilityError: (any Error)?
    public let retryError: (any Error)?
    public let reconciliationError: (any Error)?
    public let cleanupError: (any Error)?

    init(
        operation: ZhulongJournalMutationOperation,
        disposition: ZhulongJournalFailureDisposition,
        failedPhase: ZhulongApplicationJournalMutationPhase,
        underlyingError: any Error,
        durabilityError: (any Error)? = nil,
        retryError: (any Error)? = nil,
        reconciliationError: (any Error)? = nil,
        cleanupError: (any Error)? = nil
    ) {
        self.operation = operation
        self.disposition = disposition
        self.failedPhase = failedPhase
        self.underlyingError = underlyingError
        self.durabilityError = durabilityError
        self.retryError = retryError
        self.reconciliationError = reconciliationError
        self.cleanupError = cleanupError
    }
}

enum ZhulongJournalMonitoringResolution: String {
    case committed
    case recoveredCommitted
    case notCommitted
    case unresolved
    case fileSyncFallback
    case cleanupFailure
    case temporaryCleanupCommitted
    case fenceResolved
}

struct ZhulongApplicationJournalMonitoringEvent: Equatable {
    let operation: ZhulongJournalMutationOperation
    let phase: ZhulongApplicationJournalMutationPhase
    let resolution: ZhulongJournalMonitoringResolution
    let errorKind: ZhulongErrorKind
    let errorCode: Int?

    init(
        operation: ZhulongJournalMutationOperation,
        phase: ZhulongApplicationJournalMutationPhase,
        resolution: ZhulongJournalMonitoringResolution,
        error: (any Error)? = nil
    ) {
        self.operation = operation
        self.phase = phase
        self.resolution = resolution
        let telemetry = ZhulongErrorTelemetry(error)
        errorKind = telemetry.kind
        errorCode = telemetry.code
    }
}

typealias ZhulongApplicationJournalMonitor = @Sendable (
    ZhulongApplicationJournalMonitoringEvent
) -> Void

struct ZhulongJournalDarwinOperations: @unchecked Sendable {
    var openExclusiveFile: (URL) throws -> Int32
    var setOwnerOnlyPermissions: (Int32) throws -> Void
    var writeChunk: (Int32, Data, Int) throws -> Int
    var fullSyncFile: (Int32) throws -> Void
    var syncFile: (Int32) throws -> Void
    var closeDescriptor: (Int32) throws -> Void
    var renameExclusive: (URL, URL) throws -> Void
    var openDirectory: (URL) throws -> Int32
    var syncDirectory: (Int32) throws -> Void
    var removeFile: (URL) throws -> Void
    var removeSecureTemporaryFile: (URL) throws -> Bool
    var readFile: (URL) throws -> Data?

    static let live = Self(
        openExclusiveFile: { url in
            try openFile(
                at: url,
                flags: O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                mode: mode_t(S_IRUSR | S_IWUSR)
            )
        },
        setOwnerOnlyPermissions: { descriptor in
            guard fchmod(
                descriptor,
                mode_t(S_IRUSR | S_IWUSR)
            ) == 0 else {
                throw posixError(errno)
            }
        },
        writeChunk: { descriptor, data, offset in
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else { throw posixError(errno) }
                return count
            }
        },
        fullSyncFile: { descriptor in
            while fcntl(descriptor, F_FULLFSYNC) != 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
        },
        syncFile: { descriptor in
            while fsync(descriptor) != 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
        },
        closeDescriptor: { descriptor in
            guard Darwin.close(descriptor) == 0 else {
                throw posixError(errno)
            }
        },
        renameExclusive: { source, destination in
            let result = source.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else {
                        return Int32.min
                    }
                    return renamex_np(
                        sourcePath,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result != Int32.min else {
                throw ZhulongApplicationJournalInternalError
                    .invalidFileSystemRepresentation
            }
            guard result == 0 else { throw posixError(errno) }
        },
        openDirectory: { url in
            try openFile(
                at: url,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                mode: 0
            )
        },
        syncDirectory: { descriptor in
            while fsync(descriptor) != 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
        },
        removeFile: { url in
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32.min }
                return Darwin.unlink(path)
            }
            guard result != Int32.min else {
                throw ZhulongApplicationJournalInternalError
                    .invalidFileSystemRepresentation
            }
            guard result == 0 else { throw posixError(errno) }
        },
        removeSecureTemporaryFile: { url in
            try removeSecureRegularFile(at: url)
        },
        readFile: { url in
            try readRegularFile(at: url)
        }
    )

    private static func openFile(
        at url: URL,
        flags: Int32,
        mode: mode_t
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32.min }
            return Darwin.open(path, flags, mode)
        }
        guard descriptor != Int32.min else {
            throw ZhulongApplicationJournalInternalError
                .invalidFileSystemRepresentation
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        return descriptor
    }

    private static func readRegularFile(at url: URL) throws -> Data? {
        let descriptor: Int32
        do {
            descriptor = try openFile(
                at: url,
                flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
                mode: 0
            )
        } catch {
            if isPOSIXError(error, code: ENOENT) { return nil }
            throw error
        }

        var primaryError: (any Error)?
        var data = Data()
        do {
            try validateRegularFile(descriptor)
            data = try readData(descriptor)
        } catch {
            primaryError = error
        }

        do {
            try Self.live.closeDescriptor(descriptor)
        } catch where primaryError == nil {
            throw error
        } catch {
            // A read or validation error is already the primary observation.
        }
        if let primaryError { throw primaryError }
        return data
    }

    private static func removeSecureRegularFile(at url: URL) throws -> Bool {
        guard let descriptor = try openSecureRemovalCandidate(at: url) else {
            return false
        }
        defer { _ = Darwin.close(descriptor) }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            throw posixError(errno)
        }
        guard isSecureTemporaryFileStatus(
            descriptorStatus,
            effectiveUserID: geteuid()
        ) else {
            return false
        }
        guard try pathStillMatchesSecureCandidate(
            at: url,
            descriptorStatus: descriptorStatus
        ) else {
            return false
        }

        return try unlinkIfPresent(url)
    }

    private static func openSecureRemovalCandidate(
        at url: URL
    ) throws -> Int32? {
        do {
            return try openFile(
                at: url,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode: 0
            )
        } catch {
            if isPOSIXError(error, code: ENOENT) || isPOSIXError(error, code: ELOOP) {
                return nil
            }
            throw error
        }
    }

    private static func pathStillMatchesSecureCandidate(
        at url: URL,
        descriptorStatus: stat
    ) throws -> Bool {
        var pathStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32.min }
            return lstat(path, &pathStatus)
        }
        guard result != Int32.min else {
            throw ZhulongApplicationJournalInternalError
                .invalidFileSystemRepresentation
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw posixError(errno)
        }
        return pathStatus.st_dev == descriptorStatus.st_dev
            && pathStatus.st_ino == descriptorStatus.st_ino
            && isSecureTemporaryFileStatus(
                pathStatus,
                effectiveUserID: geteuid()
            )
    }

    private static func unlinkIfPresent(_ url: URL) throws -> Bool {
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32.min }
            return Darwin.unlink(path)
        }
        guard result != Int32.min else {
            throw ZhulongApplicationJournalInternalError
                .invalidFileSystemRepresentation
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw posixError(errno)
        }
        return true
    }

    static func isSecureTemporaryFileStatus(
        _ status: stat,
        effectiveUserID: uid_t
    ) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_nlink == 1
            && status.st_uid == effectiveUserID
            && status.st_mode & mode_t(0o777) == mode_t(0o600)
    }

    private static func validateRegularFile(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError(errno)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ZhulongApplicationJournalInternalError.notARegularFile
        }
        guard status.st_nlink == 1 else {
            throw ZhulongApplicationJournalInternalError.unexpectedLinkCount
        }
        guard status.st_uid == geteuid() else {
            throw ZhulongApplicationJournalInternalError.foreignOwner
        }
        guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw ZhulongApplicationJournalInternalError.insecurePermissions
        }
    }

    private static func readData(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw posixError(errno)
        }
    }

    private static func isPOSIXError(
        _ error: any Error,
        code: Int32
    ) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(code)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private enum ZhulongApplicationJournalInternalError: ZhulongInternalTelemetryError {
    case invalidFileSystemRepresentation
    case notARegularFile
    case unexpectedLinkCount
    case foreignOwner
    case insecurePermissions
    case authenticationFailed
    case finalPrepareStateMismatch
    case finalClearStateMismatch
    case finalFenceStateMismatch
}

struct ZhulongApplicationJournalFileCommitter: @unchecked Sendable {
    let operations: ZhulongJournalDarwinOperations
    let monitor: ZhulongApplicationJournalMonitor

    init(
        operations: ZhulongJournalDarwinOperations = .live,
        monitor: @escaping ZhulongApplicationJournalMonitor = Self.liveMonitor
    ) {
        self.operations = operations
        self.monitor = monitor
    }

    func install(
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let operation = ZhulongJournalMutationOperation.prepare
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
        var descriptor: Int32?
        var descriptorOwnershipConsumed = false
        var phase = ZhulongApplicationJournalMutationPhase.temporaryOpen
        do {
            descriptor = try operations.openExclusiveFile(temporaryURL)
            guard let descriptor else {
                throw ZhulongApplicationJournalInternalError
                    .invalidFileSystemRepresentation
            }
            phase = .temporaryPermissions
            try operations.setOwnerOnlyPermissions(descriptor)
            phase = .temporaryWrite
            try writeAll(
                exactBytes,
                to: descriptor
            )
            phase = .temporaryFullSync
            do {
                try operations.fullSyncFile(descriptor)
            } catch where Self.fullSyncIsUnsupported(error) {
                monitor(
                    ZhulongApplicationJournalMonitoringEvent(
                        operation: operation,
                        phase: .temporaryFileSync,
                        resolution: .fileSyncFallback,
                        error: error
                    )
                )
                phase = .temporaryFileSync
                try operations.syncFile(descriptor)
            }
            phase = .temporaryClose
            descriptorOwnershipConsumed = true
            try operations.closeDescriptor(descriptor)
        } catch {
            var cleanupError: (any Error)?
            if let descriptor, descriptorOwnershipConsumed == false {
                do {
                    try operations.closeDescriptor(descriptor)
                } catch {
                    cleanupError = error
                }
            }
            let tempRemovalError = cleanupTemporaryFile(
                temporaryURL,
                operation: operation
            )
            cleanupError = cleanupError ?? tempRemovalError
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: operation,
                disposition: .notCommitted,
                failedPhase: phase,
                underlyingError: error,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        }

        phase = .replacement
        do {
            try operations.renameExclusive(temporaryURL, destination)
        } catch {
            let cleanupError = cleanupTemporaryFile(
                temporaryURL,
                operation: operation
            )
            return try reconcileInstallAfterReplacementError(
                exactBytes: exactBytes,
                at: destination,
                replacementError: error,
                cleanupError: cleanupError,
                authenticate: authenticate
            )
        }

        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: operation,
                phase: &phase
            )
        } catch {
            if phase != .directoryClose {
                return try retryInstallDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: phase,
                        primaryError: error
                    ),
                    authenticate: authenticate
                )
            }
            if Self.closeErrorConfirmsPriorSync(error) == false {
                return try retryInstallAfterAdverseClose(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: phase,
                        primaryError: error,
                        firstDirectoryError: error
                    ),
                    authenticate: authenticate
                )
            }
            return try recoverInstallAfterDurableDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                failedPhase: phase,
                underlyingError: error,
                authenticate: authenticate
            )
        }

        return try finishInstall(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
    }

    func remove(
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let operation = ZhulongJournalMutationOperation.clear
        var phase = ZhulongApplicationJournalMutationPhase.removal
        do {
            try operations.removeFile(destination)
        } catch {
            return try reconcileRemovalAfterRemovalError(
                exactBytes: exactBytes,
                at: destination,
                removalError: error,
                authenticate: authenticate
            )
        }

        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: operation,
                phase: &phase
            )
        } catch {
            if phase != .directoryClose {
                return try retryRemovalDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: phase,
                        primaryError: error
                    ),
                    authenticate: authenticate
                )
            }
            if Self.closeErrorConfirmsPriorSync(error) == false {
                return try retryRemovalAfterAdverseClose(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: phase,
                        primaryError: error,
                        firstDirectoryError: error
                    ),
                    authenticate: authenticate
                )
            }
            return try recoverRemovalAfterDurableDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                failedPhase: phase,
                underlyingError: error,
                authenticate: authenticate
            )
        }

        return try finishRemoval(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
    }

    func read(at url: URL) throws -> Data? {
        try operations.readFile(url)
    }

    func cleanupOrphanedTemporaryFiles(
        for destination: URL
    ) throws {
        let directoryURL = destination.deletingLastPathComponent()
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: directoryURL.path
            )
        } catch {
            let failure = temporaryCleanupFailure(
                operation: .prepare,
                underlyingError: error
            )
            record(failure)
            throw failure
        }

        var removedAny = false
        var removalError: (any Error)?
        for name in names where Self.isCanonicalTemporaryFileName(
            name,
            destinationName: destination.lastPathComponent
        ) {
            let candidateURL = directoryURL.appendingPathComponent(
                name,
                isDirectory: false
            )
            do {
                if try operations.removeSecureTemporaryFile(candidateURL) {
                    removedAny = true
                }
            } catch {
                removalError = error
                break
            }
        }

        if removedAny {
            try synchronizeTemporaryCleanupDirectory(
                directoryURL,
                operation: .prepare,
                primaryError: removalError
            )
        }
        if let removalError {
            let failure = temporaryCleanupFailure(
                operation: .prepare,
                underlyingError: removalError
            )
            record(failure)
            throw failure
        }
    }

    func resolveUncertainMutation(
        operation: ZhulongJournalMutationOperation,
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) throws -> Bool {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: operation,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try finishFenceResolution(
                    operation: operation,
                    exactBytes: exactBytes,
                    at: destination,
                    recoveredError: error,
                    authenticate: authenticate
                )
            }
            return try retryFenceDirectorySync(
                operation: operation,
                exactBytes: exactBytes,
                at: destination,
                recovery: ZhulongJournalSyncRecovery(
                    resolutionPhase: phase,
                    primaryError: error
                ),
                authenticate: authenticate
            )
        }
        return try finishFenceResolution(
            operation: operation,
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
    }

    private func retryFenceDirectorySync(
        operation: ZhulongJournalMutationOperation,
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> Bool {
        var retryPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: operation,
                phase: &retryPhase
            )
        } catch {
            if retryPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try finishFenceResolution(
                    operation: operation,
                    exactBytes: exactBytes,
                    at: destination,
                    recoveredError: recovery.primaryError,
                    authenticate: authenticate
                )
            }
            let observation = observe(
                exactBytes: exactBytes,
                at: destination,
                authenticate: authenticate
            )
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: operation,
                disposition: .unresolved,
                failedPhase: recovery.resolutionPhase,
                underlyingError: recovery.primaryError,
                retryError: error,
                reconciliationError: observation.error
            )
            record(failure)
            throw failure
        }
        return try finishFenceResolution(
            operation: operation,
            exactBytes: exactBytes,
            at: destination,
            recoveredError: recovery.primaryError,
            authenticate: authenticate
        )
    }

    private func finishFenceResolution(
        operation: ZhulongJournalMutationOperation,
        exactBytes: Data,
        at destination: URL,
        recoveredError: (any Error)? = nil,
        authenticate: (Data) throws -> Bool
    ) throws -> Bool {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        let isPresent: Bool
        switch observation {
        case .absent:
            isPresent = false
        case .authenticatedExact:
            isPresent = true
        case let .unresolved(observationError):
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: operation,
                disposition: .unresolved,
                failedPhase: .observation,
                underlyingError: ZhulongApplicationJournalInternalError
                    .finalFenceStateMismatch,
                reconciliationError: observationError
            )
            record(failure)
            throw failure
        }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: operation,
                phase: .complete,
                resolution: .fenceResolved,
                error: recoveredError
            )
        )
        return isPresent
    }

    private func synchronizeDirectory(
        _ directoryURL: URL,
        operation: ZhulongJournalMutationOperation,
        phase: inout ZhulongApplicationJournalMutationPhase
    ) throws {
        phase = .directoryOpen
        let descriptor = try operations.openDirectory(directoryURL)
        var ownershipConsumed = false
        do {
            phase = .directorySync
            try operations.syncDirectory(descriptor)
            phase = .directoryClose
            ownershipConsumed = true
            try operations.closeDescriptor(descriptor)
        } catch {
            if ownershipConsumed == false {
                do {
                    try operations.closeDescriptor(descriptor)
                } catch {
                    monitor(
                        ZhulongApplicationJournalMonitoringEvent(
                            operation: operation,
                            phase: .directoryClose,
                            resolution: .cleanupFailure,
                            error: error
                        )
                    )
                }
            }
            throw error
        }
    }

    private func synchronizeTemporaryCleanupDirectory(
        _ directoryURL: URL,
        operation: ZhulongJournalMutationOperation,
        primaryError: (any Error)? = nil
    ) throws {
        var firstPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                directoryURL,
                operation: operation,
                phase: &firstPhase
            )
        } catch {
            if firstPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                recordTemporaryCleanupCommitted(
                    operation: operation,
                    recoveredError: primaryError ?? error
                )
                return
            }
            let firstError = error
            var retryPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
            do {
                try synchronizeDirectory(
                    directoryURL,
                    operation: operation,
                    phase: &retryPhase
                )
            } catch {
                if retryPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                    recordTemporaryCleanupCommitted(
                        operation: operation,
                        recoveredError: primaryError ?? firstError
                    )
                    return
                }
                let failure = if let primaryError {
                    temporaryCleanupFailure(
                        operation: operation,
                        underlyingError: primaryError,
                        durabilityError: firstError,
                        retryError: error
                    )
                } else {
                    temporaryCleanupFailure(
                        operation: operation,
                        underlyingError: firstError,
                        retryError: error
                    )
                }
                record(failure)
                throw failure
            }
            recordTemporaryCleanupCommitted(
                operation: operation,
                recoveredError: primaryError ?? firstError
            )
            return
        }
        recordTemporaryCleanupCommitted(
            operation: operation,
            recoveredError: primaryError
        )
    }

    private func recordTemporaryCleanupCommitted(
        operation: ZhulongJournalMutationOperation,
        recoveredError: (any Error)?
    ) {
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: operation,
                phase: .temporaryCleanup,
                resolution: .temporaryCleanupCommitted,
                error: recoveredError
            )
        )
    }

    private func temporaryCleanupFailure(
        operation: ZhulongJournalMutationOperation,
        underlyingError: any Error,
        durabilityError: (any Error)? = nil,
        retryError: (any Error)? = nil
    ) -> ZhulongApplicationJournalMutationFailure {
        ZhulongApplicationJournalMutationFailure(
            operation: operation,
            disposition: .unresolved,
            failedPhase: .temporaryCleanup,
            underlyingError: underlyingError,
            durabilityError: durabilityError,
            retryError: retryError
        )
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        var offset = 0
        while offset < data.count {
            do {
                let count = try operations.writeChunk(
                    descriptor,
                    data,
                    offset
                )
                guard count > 0, count <= data.count - offset else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO)
                    )
                }
                offset += count
            } catch where Self.isPOSIXError(error, code: EINTR) {
                continue
            }
        }
    }

    private func reconcileInstallAfterReplacementError(
        exactBytes: Data,
        at destination: URL,
        replacementError: any Error,
        cleanupError: (any Error)? = nil,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        switch observation {
        case .absent, .authenticatedExact:
            return try synchronizeInstallAfterReplacementError(
                exactBytes: exactBytes,
                at: destination,
                replacementError: replacementError,
                cleanupError: cleanupError,
                authenticate: authenticate
            )
        case let .unresolved(observationError):
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: .replacement,
                underlyingError: replacementError,
                reconciliationError: observationError,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        }
    }

    private func synchronizeInstallAfterReplacementError(
        exactBytes: Data,
        at destination: URL,
        replacementError: any Error,
        cleanupError: (any Error)?,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .prepare,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose {
                if Self.closeErrorConfirmsPriorSync(error) {
                    return try resolveReplacementAfterDurableDirectorySync(
                        exactBytes: exactBytes,
                        at: destination,
                        replacementError: replacementError,
                        cleanupError: cleanupError ?? error,
                        authenticate: authenticate
                    )
                }
                return try retryReplacementAfterAdverseClose(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: .replacement,
                        primaryError: replacementError,
                        firstDirectoryError: error,
                        cleanupError: cleanupError
                    ),
                    authenticate: authenticate
                )
            }
            return try retryReplacementDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                recovery: ZhulongJournalSyncRecovery(
                    resolutionPhase: .replacement,
                    primaryError: replacementError,
                    firstDirectoryError: error,
                    cleanupError: cleanupError
                ),
                authenticate: authenticate
            )
        }
        return try resolveReplacementAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            replacementError: replacementError,
            cleanupError: cleanupError,
            authenticate: authenticate
        )
    }

    private func resolveReplacementAfterDurableDirectorySync(
        exactBytes: Data,
        at destination: URL,
        replacementError: any Error,
        cleanupError: (any Error)? = nil,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        switch observation {
        case .absent:
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .notCommitted,
                failedPhase: .replacement,
                underlyingError: replacementError,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        case .authenticatedExact:
            monitor(
                ZhulongApplicationJournalMonitoringEvent(
                    operation: .prepare,
                    phase: .replacement,
                    resolution: .recoveredCommitted,
                    error: replacementError
                )
            )
            return .recoveredCommitted(after: .replacement)
        case let .unresolved(observationError):
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: .replacement,
                underlyingError: replacementError,
                reconciliationError: observationError,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        }
    }

    private func recoverInstallAfterDurableDirectorySync(
        exactBytes: Data,
        at destination: URL,
        failedPhase: ZhulongApplicationJournalMutationPhase,
        underlyingError: any Error,
        cleanupError: (any Error)? = nil,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        guard case .authenticatedExact = observation else {
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: failedPhase,
                underlyingError: underlyingError,
                reconciliationError: observation.error,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: .prepare,
                phase: failedPhase,
                resolution: .recoveredCommitted,
                error: underlyingError
            )
        )
        return .recoveredCommitted(after: failedPhase)
    }

    private func finishInstall(
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        guard case .authenticatedExact = observation else {
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: .observation,
                underlyingError: ZhulongApplicationJournalInternalError
                    .finalPrepareStateMismatch,
                reconciliationError: observation.error
            )
            record(failure)
            throw failure
        }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: .prepare,
                phase: .complete,
                resolution: .committed
            )
        )
        return .committed
    }

    private func retryReplacementAfterAdverseClose(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .prepare,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try resolveReplacementAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    replacementError: recovery.primaryError,
                    cleanupError: recovery.cleanupError ?? error,
                    authenticate: authenticate
                )
            }
            return try retryReplacementDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                recovery: recovery.addingDirectoryError(error),
                authenticate: authenticate
            )
        }
        return try resolveReplacementAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            replacementError: recovery.primaryError,
            cleanupError: recovery.cleanupError,
            authenticate: authenticate
        )
    }

    private func retryReplacementDirectorySync(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var retryPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .prepare,
                phase: &retryPhase
            )
        } catch {
            if retryPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try resolveReplacementAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    replacementError: recovery.primaryError,
                    cleanupError: recovery.cleanupError ?? error,
                    authenticate: authenticate
                )
            }
            let observation = observe(
                exactBytes: exactBytes,
                at: destination,
                authenticate: authenticate
            )
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: recovery.resolutionPhase,
                underlyingError: recovery.primaryError,
                durabilityError: recovery.firstDirectoryError,
                retryError: error,
                reconciliationError: observation.error,
                cleanupError: recovery.cleanupError
            )
            record(failure)
            throw failure
        }
        return try resolveReplacementAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            replacementError: recovery.primaryError,
            cleanupError: recovery.cleanupError,
            authenticate: authenticate
        )
    }

    private func retryInstallAfterAdverseClose(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .prepare,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try recoverInstallAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    failedPhase: recovery.resolutionPhase,
                    underlyingError: recovery.primaryError,
                    cleanupError: recovery.cleanupError ?? error,
                    authenticate: authenticate
                )
            }
            return try retryInstallDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                recovery: recovery.addingDirectoryError(error),
                authenticate: authenticate
            )
        }
        return try recoverInstallAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            failedPhase: recovery.resolutionPhase,
            underlyingError: recovery.primaryError,
            cleanupError: recovery.cleanupError,
            authenticate: authenticate
        )
    }

    private func retryInstallDirectorySync(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var retryPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .prepare,
                phase: &retryPhase
            )
        } catch {
            if retryPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try recoverInstallAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    failedPhase: recovery.resolutionPhase,
                    underlyingError: recovery.primaryError,
                    cleanupError: recovery.cleanupError ?? error,
                    authenticate: authenticate
                )
            }
            let observation = observe(
                exactBytes: exactBytes,
                at: destination,
                authenticate: authenticate
            )
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .prepare,
                disposition: .unresolved,
                failedPhase: recovery.resolutionPhase,
                underlyingError: recovery.primaryError,
                durabilityError: recovery.firstDirectoryError,
                retryError: error,
                reconciliationError: observation.error,
                cleanupError: recovery.cleanupError
            )
            record(failure)
            throw failure
        }

        return try recoverInstallAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            failedPhase: recovery.resolutionPhase,
            underlyingError: recovery.primaryError,
            cleanupError: recovery.cleanupError,
            authenticate: authenticate
        )
    }

    private func finishRemoval(
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        guard case .absent = observation else {
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .clear,
                disposition: .unresolved,
                failedPhase: .observation,
                underlyingError: ZhulongApplicationJournalInternalError
                    .finalClearStateMismatch,
                reconciliationError: observation.error
            )
            record(failure)
            throw failure
        }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: .clear,
                phase: .complete,
                resolution: .committed
            )
        )
        return .committed
    }

    private func reconcileRemovalAfterRemovalError(
        exactBytes: Data,
        at destination: URL,
        removalError: any Error,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        switch observation {
        case .absent:
            return try synchronizeRemovalAfterRemovalError(
                exactBytes: exactBytes,
                at: destination,
                removalError: removalError,
                authenticate: authenticate
            )
        case .authenticatedExact:
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .clear,
                disposition: .notCommitted,
                failedPhase: .removal,
                underlyingError: removalError
            )
            record(failure)
            throw failure
        case let .unresolved(observationError):
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .clear,
                disposition: .unresolved,
                failedPhase: .removal,
                underlyingError: removalError,
                reconciliationError: observationError
            )
            record(failure)
            throw failure
        }
    }

    private func synchronizeRemovalAfterRemovalError(
        exactBytes: Data,
        at destination: URL,
        removalError: any Error,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .clear,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose {
                if Self.closeErrorConfirmsPriorSync(error) {
                    return try recoverRemovalAfterDurableDirectorySync(
                        exactBytes: exactBytes,
                        at: destination,
                        failedPhase: .removal,
                        underlyingError: removalError,
                        cleanupError: error,
                        authenticate: authenticate
                    )
                }
                return try retryRemovalAfterAdverseClose(
                    exactBytes: exactBytes,
                    at: destination,
                    recovery: ZhulongJournalSyncRecovery(
                        resolutionPhase: .removal,
                        primaryError: removalError,
                        firstDirectoryError: error
                    ),
                    authenticate: authenticate
                )
            }
            return try retryRemovalDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                recovery: ZhulongJournalSyncRecovery(
                    resolutionPhase: .removal,
                    primaryError: removalError,
                    firstDirectoryError: error
                ),
                authenticate: authenticate
            )
        }
        return try recoverRemovalAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            failedPhase: .removal,
            underlyingError: removalError,
            authenticate: authenticate
        )
    }

    private func retryRemovalAfterAdverseClose(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var phase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .clear,
                phase: &phase
            )
        } catch {
            if phase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try recoverRemovalAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    failedPhase: recovery.resolutionPhase,
                    underlyingError: recovery.primaryError,
                    cleanupError: recovery.cleanupError ?? error,
                    authenticate: authenticate
                )
            }
            return try retryRemovalDirectorySync(
                exactBytes: exactBytes,
                at: destination,
                recovery: recovery.addingDirectoryError(error),
                authenticate: authenticate
            )
        }
        return try recoverRemovalAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            failedPhase: recovery.resolutionPhase,
            underlyingError: recovery.primaryError,
            cleanupError: recovery.cleanupError,
            authenticate: authenticate
        )
    }

    private func retryRemovalDirectorySync(
        exactBytes: Data,
        at destination: URL,
        recovery: ZhulongJournalSyncRecovery,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        var retryPhase = ZhulongApplicationJournalMutationPhase.directoryOpen
        do {
            try synchronizeDirectory(
                destination.deletingLastPathComponent(),
                operation: .clear,
                phase: &retryPhase
            )
        } catch {
            if retryPhase == .directoryClose, Self.closeErrorConfirmsPriorSync(error) {
                return try recoverRemovalAfterDurableDirectorySync(
                    exactBytes: exactBytes,
                    at: destination,
                    failedPhase: recovery.resolutionPhase,
                    underlyingError: recovery.primaryError,
                    cleanupError: error,
                    authenticate: authenticate
                )
            }
            let observation = observe(
                exactBytes: exactBytes,
                at: destination,
                authenticate: authenticate
            )
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .clear,
                disposition: .unresolved,
                failedPhase: recovery.resolutionPhase,
                underlyingError: recovery.primaryError,
                durabilityError: recovery.firstDirectoryError,
                retryError: error,
                reconciliationError: observation.error
            )
            record(failure)
            throw failure
        }
        return try recoverRemovalAfterDurableDirectorySync(
            exactBytes: exactBytes,
            at: destination,
            failedPhase: recovery.resolutionPhase,
            underlyingError: recovery.primaryError,
            authenticate: authenticate
        )
    }

    private func recoverRemovalAfterDurableDirectorySync(
        exactBytes: Data,
        at destination: URL,
        failedPhase: ZhulongApplicationJournalMutationPhase,
        underlyingError: any Error,
        cleanupError: (any Error)? = nil,
        authenticate: (Data) throws -> Bool
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        let observation = observe(
            exactBytes: exactBytes,
            at: destination,
            authenticate: authenticate
        )
        guard case .absent = observation else {
            let failure = ZhulongApplicationJournalMutationFailure(
                operation: .clear,
                disposition: .unresolved,
                failedPhase: failedPhase,
                underlyingError: underlyingError,
                reconciliationError: observation.error,
                cleanupError: cleanupError
            )
            record(failure)
            throw failure
        }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: .clear,
                phase: failedPhase,
                resolution: .recoveredCommitted,
                error: underlyingError
            )
        )
        return .recoveredCommitted(after: failedPhase)
    }

    private func observe(
        exactBytes: Data,
        at destination: URL,
        authenticate: (Data) throws -> Bool
    ) -> ZhulongApplicationJournalFileObservation {
        let candidate: Data
        do {
            guard let bytes = try operations.readFile(destination) else {
                return .absent
            }
            candidate = bytes
        } catch {
            return .unresolved(error)
        }
        guard candidate == exactBytes else {
            return .unresolved(nil)
        }
        do {
            guard try authenticate(candidate) else {
                return .unresolved(
                    ZhulongApplicationJournalInternalError
                        .authenticationFailed
                )
            }
            return .authenticatedExact
        } catch {
            return .unresolved(error)
        }
    }

    private func cleanupTemporaryFile(
        _ url: URL,
        operation: ZhulongJournalMutationOperation
    ) -> (any Error)? {
        var recoveredRemovalError: (any Error)?
        do {
            try operations.removeFile(url)
        } catch {
            if Self.isPOSIXError(error, code: ENOENT) { return nil }
            do {
                guard try operations.readFile(url) == nil else {
                    monitorTemporaryCleanupFailure(
                        operation: operation,
                        error: error
                    )
                    return error
                }
                recoveredRemovalError = error
            } catch {
                monitorTemporaryCleanupFailure(
                    operation: operation,
                    error: error
                )
                return error
            }
        }

        do {
            try synchronizeTemporaryCleanupDirectory(
                url.deletingLastPathComponent(),
                operation: operation,
                primaryError: recoveredRemovalError
            )
            return nil
        } catch {
            return error
        }
    }

    private func monitorTemporaryCleanupFailure(
        operation: ZhulongJournalMutationOperation,
        error: any Error
    ) {
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: operation,
                phase: .temporaryCleanup,
                resolution: .cleanupFailure,
                error: error
            )
        )
    }

    private func record(
        _ failure: ZhulongApplicationJournalMutationFailure
    ) {
        let resolution: ZhulongJournalMonitoringResolution =
            switch failure.disposition {
            case .notCommitted:
                .notCommitted
            case .unresolved:
                .unresolved
            }
        monitor(
            ZhulongApplicationJournalMonitoringEvent(
                operation: failure.operation,
                phase: failure.failedPhase,
                resolution: resolution,
                error: failure.underlyingError
            )
        )
    }

    private static func fullSyncIsUnsupported(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        return nsError.code == Int(EINVAL)
            || nsError.code == Int(ENOTSUP)
            || nsError.code == Int(ENOTTY)
    }

    private static func isCanonicalTemporaryFileName(
        _ name: String,
        destinationName: String
    ) -> Bool {
        let prefix = ".\(destinationName)."
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return false
        }
        let tokenStart = name.index(name.startIndex, offsetBy: prefix.count)
        let tokenEnd = name.index(name.endIndex, offsetBy: -suffix.count)
        let token = String(name[tokenStart ..< tokenEnd])
        guard token.utf8.count == 36,
              let uuid = UUID(uuidString: token)
        else {
            return false
        }
        return uuid.uuidString == token.uppercased()
    }

    private static func isPOSIXError(
        _ error: any Error,
        code: Int32
    ) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(code)
    }

    private static func closeErrorConfirmsPriorSync(
        _ error: any Error
    ) -> Bool {
        isPOSIXError(error, code: EINTR)
    }

    private static let liveMonitor: ZhulongApplicationJournalMonitor = { event in
        NSLog(
            "NoonmarkZhulongApplicationJournal operation=%@ phase=%@ resolution=%@ error_kind=%@ error_code=%@",
            event.operation.rawValue,
            event.phase.rawValue,
            event.resolution.rawValue,
            event.errorKind.rawValue,
            event.errorCode.map(String.init) ?? "none"
        )
    }
}

private struct ZhulongJournalSyncRecovery {
    let resolutionPhase: ZhulongApplicationJournalMutationPhase
    let primaryError: any Error
    let firstDirectoryError: (any Error)?
    let cleanupError: (any Error)?

    init(
        resolutionPhase: ZhulongApplicationJournalMutationPhase,
        primaryError: any Error,
        firstDirectoryError: (any Error)? = nil,
        cleanupError: (any Error)? = nil
    ) {
        self.resolutionPhase = resolutionPhase
        self.primaryError = primaryError
        self.firstDirectoryError = firstDirectoryError
        self.cleanupError = cleanupError
    }

    func addingDirectoryError(
        _ error: any Error
    ) -> ZhulongJournalSyncRecovery {
        ZhulongJournalSyncRecovery(
            resolutionPhase: resolutionPhase,
            primaryError: primaryError,
            firstDirectoryError: firstDirectoryError ?? error,
            cleanupError: cleanupError
        )
    }
}

private enum ZhulongApplicationJournalFileObservation {
    case absent
    case authenticatedExact
    case unresolved((any Error)?)

    var error: (any Error)? {
        guard case let .unresolved(error) = self else { return nil }
        return error
    }
}
