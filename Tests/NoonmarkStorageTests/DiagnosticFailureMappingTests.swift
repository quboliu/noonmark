import NoonmarkDiagnostics
@testable import NoonmarkStorage
import SQLite3
import XCTest

final class DiagnosticFailureMappingTests: XCTestCase {
    func testLocalFirstSyncFailureReasonOwnsStableDiagnosticCodes() {
        let expected: [
            (SQLiteLocalFirstSyncFailureReason, Int)
        ] = [
            (.baselineUnavailable, 1),
            (.baselineInvalid, 2),
            (.baselineNotUploaded, 3),
            (.localRecordsUnpreparable, 4),
            (.localChangesPending, 5),
            (.remoteChangesPending, 6),
            (.transportOrStorage, 7),
            (.operationInterrupted, 8)
        ]

        for (reason, code) in expected {
            XCTAssertEqual(
                reason.diagnosticFailure,
                DiagnosticFailure(domain: .syncProtocol, code: code)
            )
        }
    }

    func testRepositoryOpenFailurePreservesSQLitePrimaryCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-sqlite-diagnostic-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = root.appendingPathComponent(
            "noonmark.sqlite",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: databaseURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try SQLiteEngineRepository(databaseURL: databaseURL).load()
        ) { error in
            guard let repositoryError = error as? SQLiteRepositoryError,
                  case let .openFailed(_, sqliteCode) = repositoryError,
                  let sqliteCode
            else {
                return XCTFail("expected coded SQLite open failure, got \(error)")
            }
            XCTAssertEqual(sqliteCode & 0xFF, SQLITE_CANTOPEN)
            XCTAssertEqual(
                repositoryError.diagnosticFailure.code,
                Int(sqliteCode)
            )
        }
    }

    func testSQLiteMessageDoesNotCrossTypedFailureMapping() {
        let failure = SQLiteRepositoryError.openFailed(
            "PRIVATE-TASK-TITLE-7Q9X /Users/private/noonmark.sqlite"
        )
        .diagnosticFailure

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .sqlite, code: -1002)
        )
    }

    func testSQLiteExtendedResultCodeSurvivesTypedFailureMapping() {
        let ioWriteCode = SQLITE_IOERR | (3 << 8)
        let failure = SQLiteRepositoryError.stepFailed(
            "PRIVATE-TASK-TITLE-7Q9X",
            sqliteCode: ioWriteCode
        )
        .diagnosticFailure

        XCTAssertEqual(
            failure,
            DiagnosticFailure(
                domain: .sqlite,
                code: Int(ioWriteCode)
            )
        )
    }

    func testTransientContentionUsesSQLiteBusyCode() {
        XCTAssertEqual(
            SQLiteRepositoryError.transientContention.diagnosticFailure,
            DiagnosticFailure(domain: .sqlite, code: Int(SQLITE_BUSY))
        )
    }

    func testDataRootLeaseDropsPathButKeepsPOSIXCode() {
        let failure = NoonmarkDataRootProcessLeaseError.posixFailure(
            operation: "PRIVATE-TASK-TITLE-7Q9X",
            code: EACCES,
            path: "/Users/private/noonmark"
        )
        .diagnosticFailure

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .posix, code: Int(EACCES))
        )
    }
}
