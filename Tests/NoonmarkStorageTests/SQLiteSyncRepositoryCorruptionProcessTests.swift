import Foundation
@testable import NoonmarkStorage
import NoonmarkSync
import SQLite3
import XCTest

final class SQLiteSyncCorruptionProcessTests: XCTestCase {
    private static let phaseEnvironment =
        "NOONMARK_TEST_SQLITE_SYNC_CORRUPTION_PHASE"
    private static let databaseEnvironment =
        "NOONMARK_TEST_SQLITE_SYNC_CORRUPTION_DATABASE"
    private static let testSelector =
        "NoonmarkStorageTests.SQLiteSyncCorruptionProcessTests/" +
        "testCorruptedInvariantFieldsFailClosedWithoutTerminatingProcess"
    private static let whitespaceSQL =
        "char(9) || char(10) || char(160) || char(12288)"
    private let now = Date(timeIntervalSinceReferenceDate: 812_345_678)

    func testCorruptedInvariantFieldsFailClosedWithoutTerminatingProcess() throws {
        if let rawPhase = ProcessInfo.processInfo.environment[
            Self.phaseEnvironment
        ] {
            let phase = try XCTUnwrap(CorruptionPhase(rawValue: rawPhase))
            let databasePath = try XCTUnwrap(
                ProcessInfo.processInfo.environment[Self.databaseEnvironment]
            )
            try runChild(
                phase: phase,
                databaseURL: URL(fileURLWithPath: databasePath)
            )
            return
        }

        for phase in CorruptionPhase.allCases {
            try assertChildRejectsCorruption(phase)
        }
    }

    func testSchemaRejectsWhitespaceOnlyInvariantFields() throws {
        let databaseURL = makeDatabaseURL(suffix: "schema-check")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        try seedEveryInvariantRow(in: repository)

        let updates = [
            "UPDATE sync_device_identity SET device_id = \(Self.whitespaceSQL)",
            "UPDATE sync_metadata SET key = \(Self.whitespaceSQL)",
            "UPDATE change_journal SET device_id = \(Self.whitespaceSQL)",
            "UPDATE sync_conflicts SET local_record_id = \(Self.whitespaceSQL)",
            "UPDATE sync_conflicts SET remote_record_id = \(Self.whitespaceSQL)",
            "UPDATE sync_audit_log SET action = \(Self.whitespaceSQL)"
        ]

        for sql in updates {
            XCTAssertThrowsError(
                try executeProbeSQL(sql, at: databaseURL),
                "schema accepted whitespace-only invariant text: \(sql)"
            )
        }
    }

    private func assertChildRejectsCorruption(
        _ phase: CorruptionPhase
    ) throws {
        let databaseURL = makeDatabaseURL(suffix: phase.rawValue)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            Self.testSelector,
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.phaseEnvironment] = phase.rawValue
        environment[Self.databaseEnvironment] = databaseURL.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationReason,
            .exit,
            "phase=\(phase.rawValue)\n\(childOutput)"
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "phase=\(phase.rawValue)\n\(childOutput)"
        )
    }

    private func runChild(
        phase: CorruptionPhase,
        databaseURL: URL
    ) throws {
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        try seedEveryInvariantRow(in: repository)
        try executeProbeSQL(
            """
            PRAGMA ignore_check_constraints = ON;
            \(phase.corruptionSQL);
            """,
            at: databaseURL
        )

        switch phase {
        case .deviceIdentity:
            assertInvalidStoredValue { try repository.loadDeviceIdentity() }
        case .metadataKey:
            assertInvalidStoredValue {
                try repository.metadata(for: phase.corruptedLookupKey)
            }
        case .journalDeviceID:
            assertInvalidStoredValue { try repository.journalEntries() }
        case .conflictLocalRecordID, .conflictRemoteRecordID:
            assertInvalidStoredValue { try repository.unresolvedConflicts() }
        case .auditAction:
            assertInvalidStoredValue { try repository.auditLog() }
        }
    }

    private func seedEveryInvariantRow(
        in repository: SQLiteSyncRepository
    ) throws {
        try repository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: SyncDeviceID("corruption-device"),
                displayName: "Corruption Probe",
                createdAt: now
            )
        )
        try repository.saveMetadata(
            SyncMetadataEntry(
                key: "corruption.metadata",
                value: Data([0x01]),
                updatedAt: now
            )
        )
        try repository.appendJournalEntry(
            SyncJournalEntry(
                id: UUID(
                    uuidString: "C1000000-0000-0000-0000-000000000001"
                )!,
                entityType: .day,
                entityID: "2026-07-17",
                changedAt: now,
                deviceID: SyncDeviceID("corruption-device")
            )
        )
        let remoteRecord = SyncRecord(
            id: SyncRecordID("day:corruption-remote"),
            entityType: .day,
            entityID: "corruption-remote",
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("corruption-remote"),
            payload: Data([0x01])
        )
        try repository.saveConflict(
            SyncConflict(
                type: .invalidRecordPayload,
                entityType: .day,
                entityID: remoteRecord.entityID,
                localRecordID: SyncRecordID("day:corruption-local"),
                remoteRecord: remoteRecord,
                detectedAt: now,
                message: "corruption process probe"
            )
        )
        try repository.appendAuditLog(
            SyncAuditLogEntry(
                id: UUID(
                    uuidString: "C1000000-0000-0000-0000-000000000002"
                )!,
                direction: .download,
                entityType: .day,
                entityID: "corruption-remote",
                action: "conflict",
                createdAt: now
            )
        )
    }

    private func assertInvalidStoredValue(
        _ operation: () throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail(
                    "expected invalid stored value, got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func executeProbeSQL(
        _ sql: String,
        at databaseURL: URL
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(
                "corruption probe could not open database"
            )
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(
                "corruption probe SQL failed"
            )
        }
    }

    private func makeDatabaseURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-sync-corruption-\(suffix)-\(UUID().uuidString)"
            )
            .appendingPathExtension("sqlite")
    }
}

private enum CorruptionPhase: String, CaseIterable {
    case deviceIdentity
    case metadataKey
    case journalDeviceID
    case conflictLocalRecordID
    case conflictRemoteRecordID
    case auditAction

    private static let whitespaceSQL =
        "char(9) || char(10) || char(160) || char(12288)"

    var corruptionSQL: String {
        switch self {
        case .deviceIdentity:
            "UPDATE sync_device_identity SET device_id = \(Self.whitespaceSQL)"
        case .metadataKey:
            "UPDATE sync_metadata SET key = \(Self.whitespaceSQL)"
        case .journalDeviceID:
            "UPDATE change_journal SET device_id = \(Self.whitespaceSQL)"
        case .conflictLocalRecordID:
            "UPDATE sync_conflicts SET local_record_id = \(Self.whitespaceSQL)"
        case .conflictRemoteRecordID:
            "UPDATE sync_conflicts SET remote_record_id = \(Self.whitespaceSQL)"
        case .auditAction:
            "UPDATE sync_audit_log SET action = \(Self.whitespaceSQL)"
        }
    }

    var corruptedLookupKey: String {
        "\t\n\u{00A0}\u{3000}"
    }
}
