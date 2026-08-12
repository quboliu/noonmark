import Foundation
import SQLite3

final class SQLiteStoreRuntime: @unchecked Sendable {
    private let databaseURL: URL
    private let anchorLock = NSLock()
    private let writerCoordinator = SQLiteStoreWriterCoordinator.shared
    private var walAnchor: OpaquePointer?
    private var isFinalizedForTermination = false

    static func shared(for databaseURL: URL) -> SQLiteStoreRuntime {
        SQLiteStoreRuntimeRegistry.shared.runtime(for: databaseURL)
    }

    fileprivate init(databaseURL: URL) {
        let canonicalURL = databaseURL.standardizedFileURL
            .resolvingSymlinksInPath()
        self.databaseURL = canonicalURL
    }

    deinit {
        sqlite3_close(walAnchor)
    }

    func prepare(_ database: OpaquePointer?) throws {
        let writeLease = acquireWriteLease()
        defer { writeLease.release() }
        try SQLiteSchema.installOrValidate(on: database)
        try retainWALAttachment()
    }

    /// SQLite WAL permits concurrent readers but still has exactly one writer.
    /// Every repository targeting this database must hold this process-wide
    /// lease for the complete lifetime of a write transaction. This prevents
    /// ordinary App mutations and replication bookkeeping from surfacing
    /// `SQLITE_BUSY` to one another.
    func acquireWriteLease() -> SQLiteStoreWriteLease {
        writerCoordinator.acquire(owner: self)
    }

    var writerLeaseDepth: Int { writerCoordinator.currentOwnedDepth }

    func finalizeForTermination() throws {
        let writeLease = acquireWriteLease()
        defer { writeLease.release() }
        anchorLock.lock()
        defer { anchorLock.unlock() }
        guard isFinalizedForTermination == false else {
            return
        }
        guard let walAnchor else {
            isFinalizedForTermination = true
            return
        }

        var frameCount: Int32 = 0
        var checkpointedFrameCount: Int32 = 0
        let checkpointResult = sqlite3_wal_checkpoint_v2(
            walAnchor,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &frameCount,
            &checkpointedFrameCount
        )
        let checkpointPrimaryResult = checkpointResult & 0xFF
        guard checkpointResult == SQLITE_OK
            || checkpointPrimaryResult == SQLITE_BUSY
        else {
            throw SQLiteRepositoryError.executeFailed(
                "SQLite store termination checkpoint failed in "
                    + "\"PRAGMA wal_checkpoint(TRUNCATE)\": "
                    + lastError(walAnchor),
                sqliteCode: sqliteDiagnosticCode(walAnchor)
                    ?? checkpointResult
            )
        }

        let closeResult = sqlite3_close(walAnchor)
        guard closeResult == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(
                "SQLite store termination WAL anchor close failed: "
                    + lastError(walAnchor),
                sqliteCode: sqliteDiagnosticCode(walAnchor) ?? closeResult
            )
        }
        self.walAnchor = nil
        isFinalizedForTermination = true
    }

    private func retainWALAttachment() throws {
        anchorLock.lock()
        defer { anchorLock.unlock() }
        guard isFinalizedForTermination == false else {
            throw SQLiteRepositoryError.executeFailed(
                "SQLite store runtime is finalized for termination"
            )
        }
        guard walAnchor == nil else {
            return
        }

        var candidate: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &candidate,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK else {
            let message = candidate.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown SQLite WAL anchor open error"
            let sqliteCode = sqliteDiagnosticCode(candidate) ?? openResult
            sqlite3_close(candidate)
            throw SQLiteRepositoryError.openFailed(
                message,
                sqliteCode: sqliteCode
            )
        }
        do {
            let extendedResult = sqlite3_extended_result_codes(candidate, 1)
            guard extendedResult == SQLITE_OK else {
                throw SQLiteRepositoryError.openFailed(
                    lastError(candidate),
                    sqliteCode: sqliteDiagnosticCode(candidate) ?? extendedResult
                )
            }
            guard sqlite3_exec(
                candidate,
                """
                PRAGMA foreign_keys = ON;
                BEGIN DEFERRED TRANSACTION;
                SELECT COUNT(*) FROM sqlite_master;
                COMMIT;
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SQLiteRepositoryError.openFailed(
                    lastError(candidate),
                    sqliteCode: sqliteDiagnosticCode(candidate)
                )
            }
            walAnchor = candidate
        } catch {
            sqlite3_close(candidate)
            throw error
        }
    }

    private func lastError(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite WAL anchor error"
    }
}

final class SQLiteStoreWriteLease {
    // Keep the weakly registered runtime alive until the transaction releases
    // its writer lane. Otherwise a short-lived repository expression can drop
    // the runtime mid-transaction and a concurrent repository can create a
    // second, unrelated lock for the same database path.
    private let owner: SQLiteStoreRuntime
    private let coordinator: SQLiteStoreWriterCoordinator
    private var isReleased = false

    fileprivate init(
        owner: SQLiteStoreRuntime,
        coordinator: SQLiteStoreWriterCoordinator
    ) {
        self.owner = owner
        self.coordinator = coordinator
    }

    func release() {
        guard isReleased == false else { return }
        isReleased = true
        coordinator.release()
    }

    deinit {
        release()
    }
}

private final class SQLiteStoreRuntimeRegistry: @unchecked Sendable {
    static let shared = SQLiteStoreRuntimeRegistry()

    private final class WeakRuntime {
        weak var value: SQLiteStoreRuntime?

        init(_ value: SQLiteStoreRuntime) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var runtimes: [String: WeakRuntime] = [:]

    func runtime(for databaseURL: URL) -> SQLiteStoreRuntime {
        let standardizedURL = databaseURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let key = standardizedURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = runtimes[key]?.value {
            return existing
        }
        let runtime = SQLiteStoreRuntime(databaseURL: standardizedURL)
        runtimes[key] = WeakRuntime(runtime)
        return runtime
    }
}

/// NoonmarkStorage has one process-wide SQLite writer authority. The App owns
/// one primary data store, while staging databases are written sequentially as
/// part of import. A process-wide lane is therefore both the simplest complete
/// invariant and immune to URL aliases, inode replacement, weak runtime
/// lifetime, and repository-specific lock drift.
private final class SQLiteStoreWriterCoordinator: @unchecked Sendable {
    static let shared = SQLiteStoreWriterCoordinator()

    private let lock = NSRecursiveLock()
    private var depth = 0

    var currentOwnedDepth: Int { depth }

    func acquire(owner: SQLiteStoreRuntime) -> SQLiteStoreWriteLease {
        lock.lock()
        depth += 1
        return SQLiteStoreWriteLease(owner: owner, coordinator: self)
    }

    func release() {
        precondition(depth > 0, "SQLite writer lease depth underflow")
        depth -= 1
        lock.unlock()
    }
}
