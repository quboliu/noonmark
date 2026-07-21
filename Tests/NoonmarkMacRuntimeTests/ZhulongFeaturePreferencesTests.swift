import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class ZhulongFeaturePreferencesTests: XCTestCase {
    func testDefaultsKeepPageAndAutomaticClassificationAvailable() {
        XCTAssertEqual(
            ZhulongFeaturePreferences.defaultValue,
            ZhulongFeaturePreferences(
                pageEnabled: true,
                automaticClassificationEnabled: true
            )
        )
    }

    func testRepositoryRoundTripsIndependentSwitches() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongFeaturePreferencesRepository(defaults: defaults)
        let expected = ZhulongFeaturePreferences(
            pageEnabled: false,
            automaticClassificationEnabled: true
        )

        repository.save(expected)

        XCTAssertEqual(repository.load(), expected)
    }

    func testCorruptOrIncompleteValueFailsClosedToCurrentDefault() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongFeaturePreferencesRepository(defaults: defaults)
        defaults.set(
            Data("{\"pageEnabled\":false}".utf8),
            forKey: ZhulongFeaturePreferencesRepository.defaultStorageKey
        )
        XCTAssertEqual(repository.load(), .defaultValue)

        defaults.set(
            Data("not-json".utf8),
            forKey: ZhulongFeaturePreferencesRepository.defaultStorageKey
        )
        XCTAssertEqual(repository.load(), .defaultValue)
    }

    func testAvailabilityKeepsProviderPageAndAutomationOrthogonal() {
        let providerDisabled = ZhulongFeatureAvailability(
            providerEnabled: false,
            preferences: .init(
                pageEnabled: true,
                automaticClassificationEnabled: true
            )
        )
        XCTAssertTrue(providerDisabled.pageIsAvailable)
        XCTAssertTrue(providerDisabled.shouldEnqueueAutomaticClassification)
        XCTAssertFalse(providerDisabled.providerCanExecute)

        let pageDisabled = ZhulongFeatureAvailability(
            providerEnabled: true,
            preferences: .init(
                pageEnabled: false,
                automaticClassificationEnabled: true
            )
        )
        XCTAssertFalse(pageDisabled.pageIsAvailable)
        XCTAssertTrue(pageDisabled.shouldEnqueueAutomaticClassification)
        XCTAssertTrue(pageDisabled.providerCanExecute)

        let automationDisabled = ZhulongFeatureAvailability(
            providerEnabled: true,
            preferences: .init(
                pageEnabled: true,
                automaticClassificationEnabled: false
            )
        )
        XCTAssertTrue(automationDisabled.pageIsAvailable)
        XCTAssertFalse(automationDisabled.shouldEnqueueAutomaticClassification)
        XCTAssertFalse(automationDisabled.workerMayRun)
        XCTAssertTrue(automationDisabled.providerCanExecute)
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "ZhulongFeaturePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
