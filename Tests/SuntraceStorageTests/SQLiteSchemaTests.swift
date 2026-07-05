import XCTest
@testable import SuntraceStorage

final class SQLiteSchemaTests: XCTestCase {
    func testSchemaContainsPrototypeBackedStorageObjects() {
        let schema = SQLiteSchema.statements.joined(separator: "\n")

        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS app_preferences"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS completed_subtask_record_view"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS sync_endpoint_options_view"))
        XCTAssertTrue(schema.contains("t.status != 'returnedToPool'"))
    }
}
