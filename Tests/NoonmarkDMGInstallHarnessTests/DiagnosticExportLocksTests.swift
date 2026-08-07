import Darwin
import Foundation
@testable import NoonmarkDMGInstallHarness
import SQLite3
import XCTest

final class DiagnosticExportLocksTests: XCTestCase {
    func testDescriptorLocksBlockARealSQLiteWALWriterAndThenRelease() throws {
        let fixture = try WALFixture()
        defer { fixture.remove() }
        let locks = try fixture.locks(targetPID: getpid())
        try locks.proveContention(step: "test", ledger: nil)

        let contender = try fixture.openConnection()
        defer { sqlite3_close_v2(contender) }
        sqlite3_busy_timeout(contender, 0)
        XCTAssertEqual(
            sqlite3_exec(contender, "BEGIN IMMEDIATE", nil, nil, nil),
            SQLITE_BUSY
        )

        try locks.release(ledger: nil)
        XCTAssertEqual(
            sqlite3_exec(contender, "BEGIN IMMEDIATE", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_exec(contender, "ROLLBACK", nil, nil, nil), SQLITE_OK)
    }

    func testSpawnedHolderProvesExactChildPIDInodesAndFourFDContract() throws {
        let fixture = try WALFixture()
        defer { fixture.remove() }
        let descriptors = try fixture.boundDatabaseFiles()
        let holder = try SQLiteByteRangeLockHolder(
            executablePath: fixture.helperExecutablePath,
            databaseDescriptor: descriptors.database.descriptor,
            databaseIdentity: try descriptors.database.identity(),
            sharedMemoryDescriptor: descriptors.sharedMemory.descriptor,
            sharedMemoryIdentity: try descriptors.sharedMemory.identity(),
            watchdogSeconds: 10
        )
        let childPID = holder.childPIDForTesting

        XCTAssertGreaterThan(childPID, 1)
        XCTAssertEqual(Darwin.kill(childPID, 0), 0)
        try holder.proveLocks(
            databaseDescriptor: descriptors.database.descriptor,
            sharedMemoryDescriptor: descriptors.sharedMemory.descriptor
        )
        XCTAssertTrue(holder.evidence.contains("lock_holder=posix_spawn"))
        XCTAssertTrue(holder.evidence.contains("child_pid=\(childPID)"))
        XCTAssertTrue(holder.evidence.contains("main_dev="))
        XCTAssertTrue(holder.evidence.contains("main_ino="))
        XCTAssertTrue(holder.evidence.contains("shm_dev="))
        XCTAssertTrue(holder.evidence.contains("shm_ino="))

        try holder.shutdown()
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSpawnedHolderWatchdogReapsAStaleChildAndDropsLocks() throws {
        let fixture = try WALFixture()
        defer { fixture.remove() }
        let descriptors = try fixture.boundDatabaseFiles()
        let holder = try SQLiteByteRangeLockHolder(
            executablePath: fixture.helperExecutablePath,
            databaseDescriptor: descriptors.database.descriptor,
            databaseIdentity: try descriptors.database.identity(),
            sharedMemoryDescriptor: descriptors.sharedMemory.descriptor,
            sharedMemoryIdentity: try descriptors.sharedMemory.identity(),
            watchdogSeconds: 1
        )
        let childPID = holder.childPIDForTesting

        try holder.waitForWatchdogExpiryForTesting(timeoutSeconds: 3)

        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertThrowsError(
            try holder.proveLocks(
                databaseDescriptor: descriptors.database.descriptor,
                sharedMemoryDescriptor: descriptors.sharedMemory.descriptor
            )
        )
    }

    func testLocksRejectTargetPIDWithoutThePinnedDatabaseInodes() throws {
        let fixture = try WALFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try fixture.locks(targetPID: Int32.max)
        )
    }

    func testLocksRejectPinnedDatabaseParentSwapBeforeFileOpen() throws {
        let fixture = try WALFixture()
        defer { fixture.remove() }
        let databaseDirectory = try DescriptorBoundDirectory(
            path: CanonicalAbsolutePath(fixture.dataRoot.path)
        )
        let repositoryDirectory = try DescriptorBoundDirectory(
            path: CanonicalAbsolutePath(fixture.repositoryRoot.path)
        )
        let displaced = fixture.root.appendingPathComponent(
            "displaced-data",
            isDirectory: true
        )
        let replacement = fixture.root.appendingPathComponent(
            "replacement-data",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacement,
            withIntermediateDirectories: false
        )
        try FileManager.default.moveItem(at: fixture.dataRoot, to: displaced)
        try FileManager.default.createSymbolicLink(
            at: fixture.dataRoot,
            withDestinationURL: replacement
        )

        XCTAssertThrowsError(
            try DiagnosticExportLocks(
                databaseDirectory: databaseDirectory,
                databaseFileName: "Noonmark.sqlite",
                repositoryDirectory: repositoryDirectory,
                repositoryLockFileName: ".repository.lock",
                targetPID: getpid(),
                lockHolderExecutablePath: fixture.helperExecutablePath
            )
        )
    }
}

private final class WALFixture {
    let root: URL
    let dataRoot: URL
    let repositoryRoot: URL
    let databaseURL: URL
    let helperExecutablePath: String
    private var database: OpaquePointer?

    init() throws {
        root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/test-fixtures", isDirectory: true)
        .appendingPathComponent(
            "noonmark-descriptor-locks-\(UUID().uuidString)",
            isDirectory: true
        )
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        repositoryRoot = root.appendingPathComponent(
            "repository",
            isDirectory: true
        )
        databaseURL = dataRoot.appendingPathComponent("Noonmark.sqlite")
        helperExecutablePath = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(
            ".build/debug/NoonmarkDMGInstallHarness",
            isDirectory: false
        )
        .path
        try FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repositoryRoot,
            withIntermediateDirectories: true
        )
        guard FileManager.default.isExecutableFile(
            atPath: helperExecutablePath
        ) else {
            throw FixtureFailure.helperMissing
        }
        database = try openConnection()
        try execute(
            "PRAGMA journal_mode=WAL; "
                + "PRAGMA wal_autocheckpoint=0; "
                + "CREATE TABLE evidence(id INTEGER PRIMARY KEY, value TEXT); "
                + "INSERT INTO evidence(value) VALUES ('runtime-binding');",
            on: database
        )
        guard FileManager.default.fileExists(
            atPath: databaseURL.path + "-shm"
        ) else {
            throw FixtureFailure.sharedMemoryMissing
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func locks(targetPID: pid_t) throws -> DiagnosticExportLocks {
        try DiagnosticExportLocks(
            databaseDirectory: DescriptorBoundDirectory(
                path: CanonicalAbsolutePath(dataRoot.path)
            ),
            databaseFileName: "Noonmark.sqlite",
            repositoryDirectory: DescriptorBoundDirectory(
                path: CanonicalAbsolutePath(repositoryRoot.path)
            ),
            repositoryLockFileName: ".repository.lock",
            targetPID: targetPID,
            lockHolderExecutablePath: helperExecutablePath
        )
    }

    func boundDatabaseFiles() throws -> (
        database: DescriptorBoundFile,
        sharedMemory: DescriptorBoundFile
    ) {
        let directory = try DescriptorBoundDirectory(
            path: CanonicalAbsolutePath(dataRoot.path)
        )
        return (
            database: try directory.openExistingFile(
                named: "Noonmark.sqlite",
                writable: true
            ),
            sharedMemory: try directory.openExistingFile(
                named: "Noonmark.sqlite-shm",
                writable: true
            )
        )
    }

    func openConnection() throws -> OpaquePointer {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw FixtureFailure.sqlite(result)
        }
        return connection
    }

    func remove() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func execute(_ sql: String, on database: OpaquePointer?) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw FixtureFailure.sqlite(result)
        }
    }

    private enum FixtureFailure: Error {
        case helperMissing
        case sharedMemoryMissing
        case sqlite(Int32)
    }
}
