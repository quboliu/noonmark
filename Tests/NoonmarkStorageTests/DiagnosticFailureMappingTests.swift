import NoonmarkDiagnostics
@testable import NoonmarkStorage
import XCTest

final class DiagnosticFailureMappingTests: XCTestCase {
    func testSQLiteMessageDoesNotCrossTypedFailureMapping() {
        let failure = DiagnosticFailureClassifier.classify(
            SQLiteRepositoryError.openFailed(
                "PRIVATE-TASK-TITLE-7Q9X /Users/private/noonmark.sqlite"
            )
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .sqlite, code: 2)
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
