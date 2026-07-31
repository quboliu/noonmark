import Foundation
import SQLite3

final class SQLiteStoreRuntime: @unchecked Sendable {
    private let databaseURL: URL
    private let anchorLock = NSLock()
    private var walAnchor: OpaquePointer?
    private var isFinalizedForTermination = false

    static func shared(for databaseURL: URL) -> SQLiteStoreRuntime {
        SQLiteStoreRuntimeRegistry.shared.runtime(for: databaseURL)
    }

    fileprivate init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    deinit {
        sqlite3_close(walAnchor)
    }

    func prepare(_ database: OpaquePointer?) throws {
        try SQLiteSchema.installOrValidate(on: database)
        try retainWALAttachment()
    }

    func finalizeForTermination() throws {
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
                    + lastError(walAnchor)
            )
        }

        let closeResult = sqlite3_close(walAnchor)
        guard closeResult == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(
                "SQLite store termination WAL anchor close failed: "
                    + lastError(walAnchor)
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
            sqlite3_close(candidate)
            throw SQLiteRepositoryError.openFailed(message)
        }
        do {
            guard sqlite3_extended_result_codes(candidate, 1) == SQLITE_OK else {
                throw SQLiteRepositoryError.openFailed(
                    lastError(candidate)
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
                    lastError(candidate)
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
