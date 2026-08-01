import NoonmarkDiagnostics
@testable import NoonmarkStorage
import SQLite3
import XCTest

final class DiagnosticFailureMappingTests: XCTestCase {
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
                DiagnosticFailureClassifier.classify(error).code,
                Int(sqliteCode)
            )
        }
    }

    func testSQLiteMessageDoesNotCrossTypedFailureMapping() {
        let failure = DiagnosticFailureClassifier.classify(
            SQLiteRepositoryError.openFailed(
                "PRIVATE-TASK-TITLE-7Q9X /Users/private/noonmark.sqlite"
            )
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .sqlite, code: -1002)
        )
    }

    func testSQLiteExtendedResultCodeSurvivesTypedFailureMapping() {
        let ioWriteCode = SQLITE_IOERR | (3 << 8)
        let failure = DiagnosticFailureClassifier.classify(
            SQLiteRepositoryError.stepFailed(
                "PRIVATE-TASK-TITLE-7Q9X",
                sqliteCode: ioWriteCode
            )
        )

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
            DiagnosticFailureClassifier.classify(
                SQLiteRepositoryError.transientContention
            ),
            DiagnosticFailure(domain: .sqlite, code: Int(SQLITE_BUSY))
        )
    }

    func testDataRootLeaseDropsPathButKeepsPOSIXCode() {
        let failure = DiagnosticFailureClassifier.classify(
            NoonmarkDataRootProcessLeaseError.posixFailure(
                operation: "PRIVATE-TASK-TITLE-7Q9X",
                code: EACCES,
                path: "/Users/private/noonmark"
            )
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .posix, code: Int(EACCES))
        )
    }
}
