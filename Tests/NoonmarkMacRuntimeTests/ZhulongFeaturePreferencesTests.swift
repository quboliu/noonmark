import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class ZhulongFeaturePreferencesTests: XCTestCase {
    func testConversationPermissionCeilingCombinesDataReadingAndRemoteSending() {
        XCTAssertEqual(
            ZhulongConversationPermissionCeiling(
                dataReading: .allow,
                remoteSending: .deny
            ).decision(sendsRemotely: false),
            .allow
        )
        XCTAssertEqual(
            ZhulongConversationPermissionCeiling(
                dataReading: .allow,
                remoteSending: .deny
            ).decision(sendsRemotely: true),
            .deny
        )
        XCTAssertEqual(
            ZhulongConversationPermissionCeiling(
                dataReading: .ask,
                remoteSending: .allow
            ).decision(sendsRemotely: true),
            .ask
        )
        XCTAssertEqual(
            ZhulongConversationPermissionCeiling(
                dataReading: .deny,
                remoteSending: .allow
            ).decision(sendsRemotely: false),
            .deny
        )
    }

    func testDefaultsKeepPageAndAutomaticClassificationAvailable() {
        XCTAssertEqual(
            ZhulongFeaturePreferences.defaultValue,
            ZhulongFeaturePreferences(
                pageEnabled: true,
                automaticClassificationEnabled: true,
                conversationPermissionCeiling: .defaultValue
            )
        )
    }

    func testRepositoryRoundTripsIndependentSwitches() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongFeaturePreferencesRepository(defaults: defaults)
        let expected = ZhulongFeaturePreferences(
            pageEnabled: false,
            automaticClassificationEnabled: true,
            conversationPermissionCeiling:
            ZhulongConversationPermissionCeiling(
                dataReading: .ask,
                remoteSending: .deny
            )
        )

        repository.save(expected)

        XCTAssertEqual(repository.load(), expected)
    }

    func testCorruptOrIncompleteValueDisablesAIDataOperations() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongFeaturePreferencesRepository(defaults: defaults)
        let failClosed = ZhulongFeaturePreferences(
            pageEnabled: true,
            automaticClassificationEnabled: false,
            conversationPermissionCeiling: .init(
                dataReading: .deny,
                remoteSending: .deny
            )
        )
        defaults.set(
            Data("{\"pageEnabled\":false}".utf8),
            forKey: ZhulongFeaturePreferencesRepository.defaultStorageKey
        )
        XCTAssertEqual(repository.load(), failClosed)

        defaults.set(
            Data("not-json".utf8),
            forKey: ZhulongFeaturePreferencesRepository.defaultStorageKey
        )
        XCTAssertEqual(repository.load(), failClosed)
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
