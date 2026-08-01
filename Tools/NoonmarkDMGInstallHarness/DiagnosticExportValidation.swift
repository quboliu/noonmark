import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Holds the two persistence locks that must not be prerequisites for
/// diagnostic export. Construction is fail-closed and proves that both locks
/// are contended before the UI interaction starts.
final class DiagnosticExportLocks {
    private let databasePath: String
    private let repositoryLockPath: String
    private var database: OpaquePointer?
    private var repositoryDescriptor: Int32 = -1

    init(databasePath: String, repositoryLockPath: String) throws {
        self.databasePath = databasePath
        self.repositoryLockPath = repositoryLockPath
        try validateRegularDatabase()
        try acquireDatabaseWriter()
        do {
            try acquireRepositoryLock()
        } catch {
            releaseDatabaseWriter()
            throw error
        }
    }

    deinit {
        if repositoryDescriptor >= 0 {
            _ = flock(repositoryDescriptor, LOCK_UN)
            _ = Darwin.close(repositoryDescriptor)
        }
        releaseDatabaseWriter()
    }

    func proveContention(
        step: String,
        ledger: HarnessLedger?
    ) throws {
        try proveDatabaseContention()
        try proveRepositoryContention()
        try ledger?.pass(
            "diagnostic-locks-\(step)",
            "sqlite_writer=busy repository_flock=would-block held=true"
        )
    }

    private func validateRegularDatabase() throws {
        var status = stat()
        guard lstat(databasePath, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0
        else {
            throw contract("diagnostic database is not a nonempty regular file")
        }
        var lockStatus = stat()
        let lockResult = lstat(repositoryLockPath, &lockStatus)
        guard lockResult == 0 || errno == ENOENT else {
            throw posixFailure("inspect repository lock", code: errno)
        }
        if lockResult == 0, lockStatus.st_mode & S_IFMT != S_IFREG {
            throw contract("repository lock is not a regular file")
        }
    }

    private func acquireDatabaseWriter() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(databasePath, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw contract("open diagnostic database writer failed: sqlite=\(result)")
        }
        database = handle
        sqlite3_busy_timeout(handle, 0)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            releaseDatabaseWriter()
            throw contract("acquire diagnostic database writer failed: \(message)")
        }
    }

    private func acquireRepositoryLock() throws {
        let descriptor = repositoryLockPath.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw posixFailure("open repository lock", code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw posixFailure("acquire repository lock", code: code)
        }
        repositoryDescriptor = descriptor
    }

    private func proveDatabaseContention() throws {
        var contender: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
        let openResult = sqlite3_open_v2(
            databasePath,
            &contender,
            flags,
            nil
        )
        guard openResult == SQLITE_OK, let contender else {
            if let contender { sqlite3_close_v2(contender) }
            throw contract("open database contention probe failed")
        }
        defer { sqlite3_close_v2(contender) }
        sqlite3_busy_timeout(contender, 0)
        let result = sqlite3_exec(
            contender,
            "BEGIN IMMEDIATE",
            nil,
            nil,
            nil
        )
        guard result == SQLITE_BUSY || result == SQLITE_LOCKED else {
            if result == SQLITE_OK { sqlite3_exec(contender, "ROLLBACK", nil, nil, nil) }
            throw contract(
                "database writer contention probe returned sqlite=\(result)"
            )
        }
    }

    private func proveRepositoryContention() throws {
        let descriptor = repositoryLockPath.withCString {
            Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixFailure("open repository contention probe", code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        let result = flock(descriptor, LOCK_EX | LOCK_NB)
        guard result == -1, errno == EWOULDBLOCK else {
            if result == 0 { _ = flock(descriptor, LOCK_UN) }
            throw contract(
                "repository lock contention probe did not return EWOULDBLOCK"
            )
        }
    }

    private func releaseDatabaseWriter() {
        guard let database else { return }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(database)
        self.database = nil
    }

    private func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }

    private func posixFailure(
        _ operation: String,
        code: Int32
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(
            "\(operation) failed: errno=\(code) "
                + String(cString: strerror(code))
        )
    }
}

enum DiagnosticExportPackageProbe {
    static func verify(
        exportPath: String,
        sentinelsPath: String,
        ledger: HarnessLedger?
    ) throws {
        let sentinels = try loadSentinels(from: sentinelsPath)
        var status = stat()
        guard lstat(exportPath, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              status.st_size <= 8 * 1024 * 1024,
              status.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            throw contract(
                "diagnostic export is not a bounded owner-only regular file"
            )
        }
        let first = try Data(contentsOf: URL(fileURLWithPath: exportPath))
        let second = try Data(contentsOf: URL(fileURLWithPath: exportPath))
        guard first == second else {
            throw contract("diagnostic export changed during validation")
        }
        for sentinel in sentinels {
            guard first.range(of: Data(sentinel.utf8)) == nil else {
                throw contract("diagnostic export contains a privacy sentinel")
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: first)
            as? [String: Any],
            Set(root.keys) == Set([
                "manifest",
                "records",
                "activeOperations",
                "operationCapsules",
                "metricAttachments"
            ]),
            let manifest = root["manifest"] as? [String: Any],
            (manifest["schemaVersion"] as? NSNumber)?.intValue == 1,
            let records = root["records"] as? [Any],
            let active = root["activeOperations"] as? [Any],
            let capsules = root["operationCapsules"] as? [Any],
            let metrics = root["metricAttachments"] as? [Any],
            (manifest["recordCount"] as? NSNumber)?.intValue
            == records.count,
            (manifest["activeOperationCount"] as? NSNumber)?.intValue
            == active.count,
            (manifest["operationCapsuleCount"] as? NSNumber)?.intValue
            == capsules.count,
            (manifest["metricPayloadCount"] as? NSNumber)?.intValue
            == metrics.count
        else {
            throw contract("diagnostic export schema or manifest counts are invalid")
        }
        let digest = SHA256.hash(data: first)
            .map { String(format: "%02x", $0) }
            .joined()
        try ledger?.pass(
            "diagnostic-package",
            "schema=1 bytes=\(first.count) sha256=\(digest) "
                + "records=\(records.count) active=\(active.count) "
                + "capsules=\(capsules.count) metrics=\(metrics.count) "
                + "sentinels=absent owner_only=true"
        )
    }

    private static func loadSentinels(from path: String) throws -> [String] {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              status.st_size <= 64 * 1024
        else {
            throw contract("privacy sentinels are not a bounded regular file")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let text = String(data: data, encoding: .utf8) else {
            throw contract("privacy sentinels are not UTF-8")
        }
        let values = text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(text.hasSuffix("\n") ? 1 : 0)
            .map(String.init)
        guard values.isEmpty == false,
              values.count <= 64,
              Set(values).count == values.count,
              values.allSatisfy({
                  $0.utf8.count >= 8
                      && $0.utf8.count <= 1024
                      && $0.unicodeScalars.allSatisfy {
                          CharacterSet.controlCharacters.contains($0) == false
                      }
              })
        else {
            throw contract("privacy sentinel set is empty, duplicate, or unbounded")
        }
        return values
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }
}
