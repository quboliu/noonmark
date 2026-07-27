import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class RecurringFuturePlanVisibilityTests: XCTestCase {
    func testRepositoryDefaultsToFifteenDaysAndPersistsAllowedValues() {
        let suiteName =
            "RecurringFuturePlanVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let repository = RecurringFuturePlanVisibilityRepository(
            defaults: defaults
        )

        XCTAssertEqual(repository.load(), .fifteenDays)

        repository.save(.thirtyDays)

        XCTAssertEqual(repository.load(), .thirtyDays)
    }

    func testRepositoryFailsClosedToDefaultForUnsupportedStoredValue() {
        let suiteName =
            "RecurringFuturePlanVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let repository = RecurringFuturePlanVisibilityRepository(
            defaults: defaults
        )
        defaults.set(365, forKey: RecurringFuturePlanVisibilityRepository
            .defaultStorageKey)

        XCTAssertEqual(repository.load(), .fifteenDays)
    }
}
