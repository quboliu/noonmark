import Darwin
import Foundation

public enum NoonmarkDataRootProcessLeaseError: Error, Equatable, Sendable {
    case alreadyHeld(path: String)
    case invalidDataRoot(path: String)
    case invalidLockFile(path: String)
    case posixFailure(
        operation: String,
        code: Int32,
        path: String
    )
}

extension NoonmarkDataRootProcessLeaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyHeld:
            "Another Noonmark process is already using this data location."
        case .invalidDataRoot:
            "The Noonmark data location is not a regular directory."
        case .invalidLockFile:
            "The Noonmark data-location lock is not a regular file."
        case let .posixFailure(operation, code, path):
            "Noonmark data-location lease \(operation) failed at \(path) "
                + "with errno \(code)."
        }
    }
}

/// Holds the exclusive writer lease for one persistent Noonmark data root.
///
/// The descriptor remains open for this object's lifetime. Callers must retain
/// the lease for as long as any SQLite or sidecar operation can run.
public final class NoonmarkDataRootProcessLease: @unchecked Sendable {
    public static let lockFileName = ".noonmark-writer.lock"

    public let lockFileURL: URL
    private let descriptor: Int32

    private init(lockFileURL: URL, descriptor: Int32) {
        self.lockFileURL = lockFileURL
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        // Darwin close(2) does not promise that an EINTR result leaves the
        // descriptor open. Retrying could close a descriptor that was reused.
        _ = close(descriptor)
    }

    public static func acquire(
        dataRootURL: URL
    ) throws -> NoonmarkDataRootProcessLease {
        guard dataRootURL.isFileURL else {
            throw NoonmarkDataRootProcessLeaseError.invalidDataRoot(
                path: dataRootURL.absoluteString
            )
        }
        let rootURL = dataRootURL.standardizedFileURL
        try prepareDataRoot(rootURL)
        let lockFileURL = rootURL.appendingPathComponent(
            lockFileName,
            isDirectory: false
        )
        try validateExistingLockFile(at: lockFileURL)
        let descriptor = try openLockFile(at: lockFileURL)
        var holdsLock = false
        var transfersDescriptor = false
        defer {
            if transfersDescriptor == false {
                if holdsLock {
                    _ = flock(descriptor, LOCK_UN)
                }
                _ = close(descriptor)
            }
        }

        let descriptorStatus = try validatedLockFileStatus(
            descriptor: descriptor,
            lockFileURL: lockFileURL
        )
        try tightenLockFilePermissions(
            descriptor: descriptor,
            lockFileURL: lockFileURL
        )
        try acquireExclusiveLock(
            descriptor: descriptor,
            lockFileURL: lockFileURL
        )
        holdsLock = true
        try validateLockedPath(
            lockFileURL,
            matches: descriptorStatus
        )

        transfersDescriptor = true
        return NoonmarkDataRootProcessLease(
            lockFileURL: lockFileURL,
            descriptor: descriptor
        )
    }

    private static func validateExistingLockFile(at url: URL) throws {
        guard let status = try fileStatus(
            at: url,
            operation: "lstat-lock"
        ) else { return }
        guard isValidLockFile(status) else {
            throw NoonmarkDataRootProcessLeaseError.invalidLockFile(
                path: url.path
            )
        }
    }

    private static func openLockFile(at url: URL) throws -> Int32 {
        let result: (descriptor: Int32, errorCode: Int32) = url
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                let descriptor = open(
                    path,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    mode_t(S_IRUSR | S_IWUSR)
                )
                return (descriptor, descriptor >= 0 ? 0 : errno)
            }
        guard result.descriptor >= 0 else {
            if result.errorCode == ELOOP {
                throw NoonmarkDataRootProcessLeaseError.invalidLockFile(
                    path: url.path
                )
            }
            throw posixFailure(
                operation: "open-lock",
                code: result.errorCode,
                path: url.path
            )
        }
        return result.descriptor
    }

    private static func validatedLockFileStatus(
        descriptor: Int32,
        lockFileURL: URL
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixFailure(
                operation: "fstat-lock",
                code: errno,
                path: lockFileURL.path
            )
        }
        guard isValidLockFile(status) else {
            throw NoonmarkDataRootProcessLeaseError.invalidLockFile(
                path: lockFileURL.path
            )
        }
        return status
    }

    private static func tightenLockFilePermissions(
        descriptor: Int32,
        lockFileURL: URL
    ) throws {
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixFailure(
                operation: "fchmod-lock",
                code: errno,
                path: lockFileURL.path
            )
        }
    }

    private static func acquireExclusiveLock(
        descriptor: Int32,
        lockFileURL: URL
    ) throws {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN {
                throw NoonmarkDataRootProcessLeaseError.alreadyHeld(
                    path: lockFileURL.path
                )
            }
            throw posixFailure(
                operation: "flock-lock",
                code: code,
                path: lockFileURL.path
            )
        }
    }

    private static func validateLockedPath(
        _ lockFileURL: URL,
        matches descriptorStatus: stat
    ) throws {
        guard let linkedStatus = try fileStatus(
            at: lockFileURL,
            operation: "lstat-locked"
        ),
        isValidLockFile(linkedStatus),
        linkedStatus.st_dev == descriptorStatus.st_dev,
        linkedStatus.st_ino == descriptorStatus.st_ino
        else {
            throw NoonmarkDataRootProcessLeaseError.invalidLockFile(
                path: lockFileURL.path
            )
        }
    }

    private static func prepareDataRoot(_ url: URL) throws {
        if let status = try fileStatus(
            at: url,
            operation: "lstat-data-root"
        ) {
            guard isValidDataRoot(status) else {
                throw NoonmarkDataRootProcessLeaseError.invalidDataRoot(
                    path: url.path
                )
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch let error as NSError {
            throw posixFailure(
                operation: "create-data-root",
                code: underlyingPOSIXCode(in: error),
                path: url.path
            )
        }
        guard let status = try fileStatus(
            at: url,
            operation: "lstat-created-data-root"
        ), isValidDataRoot(status) else {
            throw NoonmarkDataRootProcessLeaseError.invalidDataRoot(
                path: url.path
            )
        }
    }

    private static func fileStatus(
        at url: URL,
        operation: String
    ) throws -> stat? {
        var status = stat()
        let result: (callResult: Int32, errorCode: Int32) = url
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                let callResult = lstat(path, &status)
                return (callResult, callResult == 0 ? 0 : errno)
            }
        if result.callResult == 0 { return status }
        if result.errorCode == ENOENT { return nil }
        throw posixFailure(
            operation: operation,
            code: result.errorCode,
            path: url.path
        )
    }

    private static func underlyingPOSIXCode(in error: NSError) -> Int32 {
        var current = error
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                if let code = Int32(exactly: current.code) {
                    return code
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey]
                as? NSError
            else { return EIO }
            current = underlying
        }
        return EIO
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegular(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isValidDataRoot(_ status: stat) -> Bool {
        let groupOrWorldWritable = status.st_mode
            & mode_t(S_IWGRP | S_IWOTH)
        return isDirectory(status)
            && status.st_uid == geteuid()
            && groupOrWorldWritable == 0
    }

    private static func isValidLockFile(_ status: stat) -> Bool {
        isRegular(status)
            && status.st_nlink == 1
            && status.st_uid == geteuid()
    }

    private static func posixFailure(
        operation: String,
        code: Int32,
        path: String
    ) -> NoonmarkDataRootProcessLeaseError {
        .posixFailure(
            operation: operation,
            code: code,
            path: path
        )
    }
}
