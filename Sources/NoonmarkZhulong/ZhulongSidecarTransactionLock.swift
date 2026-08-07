import Darwin
import Foundation

struct ZhulongSidecarTransactionLock: @unchecked Sendable {
    static let pendingApplicationFileName = "pending-application.zhj"

    let directoryURL: URL
    let fileManager: FileManager

    var pendingApplicationURL: URL {
        directoryURL.appendingPathComponent(
            Self.pendingApplicationFileName,
            isDirectory: false
        )
    }

    func assertNoPendingApplicationUnlocked() throws {
        guard ZhulongSidecarRecoveryFence.shared.isActive(
            for: directoryURL
        ) == false,
        try pendingApplicationExistsUnlocked() == false
        else {
            throw ZhulongPendingApplicationRecoveryError
                .applicationAlreadyPending
        }
    }

    func unresolvedApplicationCommit() throws -> ZhulongJournalRecoveryFence? {
        try ZhulongSidecarRecoveryFence.shared.record(for: directoryURL)
    }

    func markApplicationCommitUnresolved(
        operation: ZhulongJournalMutationOperation,
        exactBytes: Data
    ) {
        ZhulongSidecarRecoveryFence.shared.activate(
            ZhulongJournalRecoveryFence(
                operation: operation,
                exactBytes: exactBytes
            ),
            for: directoryURL
        )
    }

    func clearApplicationCommitFence() throws {
        try ZhulongSidecarRecoveryFence.shared.clear(for: directoryURL)
    }

    func pendingApplicationExistsUnlocked() throws -> Bool {
        var status = stat()
        let result = pendingApplicationURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &status)
            }
        if result == 0 {
            return true
        }
        let code = errno
        guard code == ENOENT else {
            throw posixError(
                code: code,
                path: pendingApplicationURL.path
            )
        }
        return false
    }

    func withExclusiveLock<Result>(
        beforeAcquire: (() -> Void)? = nil,
        _ operation: () throws -> Result
    ) throws -> Result {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let descriptor = lockURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return open(
                    path,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
        guard descriptor >= 0 else {
            throw posixError(code: errno, path: lockURL.path)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError(code: errno, path: lockURL.path)
        }

        beforeAcquire?()
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw posixError(code: errno, path: lockURL.path)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private var lockURL: URL {
        directoryURL.appendingPathComponent(
            ".sidecar-transaction.lock",
            isDirectory: false
        )
    }

    private func posixError(code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}

struct ZhulongJournalRecoveryFence: Equatable {
    let operation: ZhulongJournalMutationOperation
    let exactBytes: Data
}

final class ZhulongSidecarRecoveryFence: @unchecked Sendable {
    static let shared = ZhulongSidecarRecoveryFence()

    private let lock = NSLock()
    private let identityResolver: (URL) -> ZhulongSidecarDirectoryIdentities
    private var entries: [
        ZhulongSidecarDirectoryIdentity: ZhulongSidecarFenceEntry
    ] = [:]

    init(
        identityResolver: @escaping (URL) -> ZhulongSidecarDirectoryIdentities =
            ZhulongSidecarRecoveryFence.liveIdentities
    ) {
        self.identityResolver = identityResolver
    }

    func isActive(for directoryURL: URL) -> Bool {
        let identities = identityResolver(directoryURL)
        lock.lock()
        defer { lock.unlock() }
        return identities.keys.contains { entries[$0] != nil }
    }

    func record(
        for directoryURL: URL
    ) throws -> ZhulongJournalRecoveryFence? {
        let identities = identityResolver(directoryURL)
        lock.lock()
        defer { lock.unlock() }
        let group = try resolvedGroup(for: identities.keys)
        if let group {
            for key in identities.keys {
                entries[key] = .group(group)
            }
        }
        return group?.record
    }

    func activate(
        _ record: ZhulongJournalRecoveryFence,
        for directoryURL: URL
    ) {
        let identities = identityResolver(directoryURL)
        lock.lock()
        defer { lock.unlock() }
        let existingGroups: [ZhulongSidecarFenceGroup] = identities.keys
            .compactMap { key in
            guard case let .group(group) = entries[key] else { return nil }
            return group
        }
        let existingGroupIDs = Set(existingGroups.map(\.id))
        let hasConflict = identities.keys.contains {
            entries[$0] == .conflict
        }
            || existingGroupIDs.count > 1
            || existingGroups.first.map { $0.record != record } == true
        let group = existingGroups.first
            ?? ZhulongSidecarFenceGroup(record: record)
        for key in identities.keys {
            entries[key] = hasConflict ? .conflict : .group(group)
        }
    }

    func clear(for directoryURL: URL) throws {
        let identities = identityResolver(directoryURL)
        lock.lock()
        defer { lock.unlock() }
        guard let group = try resolvedGroup(for: identities.keys) else {
            return
        }
        entries = entries.filter { _, entry in
            entry.groupID != group.id
        }
    }

    private func resolvedGroup(
        for keys: Set<ZhulongSidecarDirectoryIdentity>
    ) throws -> ZhulongSidecarFenceGroup? {
        var resolved: ZhulongSidecarFenceGroup?
        for key in keys {
            guard let entry = entries[key] else { continue }
            switch entry {
            case .conflict:
                throw ZhulongSidecarFenceError.conflictingIdentity
            case let .group(group):
                if let resolved, resolved != group {
                    throw ZhulongSidecarFenceError.conflictingIdentity
                }
                resolved = group
            }
        }
        return resolved
    }

    private static func liveIdentities(
        for directoryURL: URL
    ) -> ZhulongSidecarDirectoryIdentities {
        let canonicalURL = directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let inode = openIdentity(for: directoryURL)
            ?? openIdentity(for: canonicalURL)
        return ZhulongSidecarDirectoryIdentities(
            canonicalPath: canonicalURL.path,
            inode: inode
        )
    }

    private static func openIdentity(
        for directoryURL: URL
    ) -> ZhulongSidecarDirectoryIdentity? {
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid()
        else { return nil }
        return .inode(
            device: UInt64(status.st_dev),
            node: UInt64(status.st_ino)
        )
    }
}

struct ZhulongSidecarDirectoryIdentities {
    let keys: Set<ZhulongSidecarDirectoryIdentity>

    init(
        canonicalPath: String,
        inode: ZhulongSidecarDirectoryIdentity? = nil
    ) {
        var keys: Set<ZhulongSidecarDirectoryIdentity> = [
            .canonicalPath(canonicalPath)
        ]
        if let inode {
            keys.insert(inode)
        }
        self.keys = keys
    }
}

enum ZhulongSidecarDirectoryIdentity: Hashable {
    case inode(device: UInt64, node: UInt64)
    case canonicalPath(String)
}

private struct ZhulongSidecarFenceGroup: Equatable {
    let id: UUID
    let record: ZhulongJournalRecoveryFence

    init(
        id: UUID = UUID(),
        record: ZhulongJournalRecoveryFence
    ) {
        self.id = id
        self.record = record
    }
}

private enum ZhulongSidecarFenceEntry: Equatable {
    case group(ZhulongSidecarFenceGroup)
    case conflict

    var groupID: UUID? {
        guard case let .group(group) = self else { return nil }
        return group.id
    }
}

private enum ZhulongSidecarFenceError: ZhulongInternalTelemetryError {
    case conflictingIdentity
}
