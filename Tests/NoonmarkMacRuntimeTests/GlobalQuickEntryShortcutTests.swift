import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class GlobalQuickEntryShortcutTests: XCTestCase {
    func testStandardPreferenceUsesControlShiftNAndFormatsItForPeople() {
        let preference = GlobalQuickEntryShortcutPreference.standard

        XCTAssertTrue(preference.isEnabled)
        XCTAssertEqual(preference.shortcut.key, .n)
        XCTAssertEqual(preference.shortcut.modifiers, [.control, .shift])
        XCTAssertEqual(preference.shortcut.displayText, "⌃⇧N")
    }

    func testSupportedPhysicalKeysHaveUniqueVirtualCodesAndRoundTrip() {
        let keyCodes = GlobalShortcutKey.allCases.map(\.virtualKeyCode)

        XCTAssertEqual(Set(keyCodes).count, GlobalShortcutKey.allCases.count)
        for key in GlobalShortcutKey.allCases {
            XCTAssertEqual(
                GlobalShortcutKey(virtualKeyCode: key.virtualKeyCode),
                key
            )
        }
        XCTAssertNil(GlobalShortcutKey(virtualKeyCode: UInt16.max))
    }

    func testRepositoryRoundTripsAndFailsClosedWhenStoredValueIsCorrupt() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )

        XCTAssertEqual(repository.load(), .standard)

        let customized = GlobalQuickEntryShortcutPreference(
            isEnabled: true,
            shortcut: GlobalQuickEntryShortcut(
                key: .k,
                modifiers: [.command, .option]
            )
        )
        repository.save(customized)
        XCTAssertEqual(repository.load(), customized)

        defaults.set(
            Data("not-json".utf8),
            forKey: GlobalShortcutPreferenceRepository
                .defaultStorageKey
        )
        XCTAssertEqual(
            repository.load(),
            GlobalQuickEntryShortcutPreference(
                isEnabled: false,
                shortcut: .standard
            )
        )
    }

    func testPolicyRejectsUnsafeNoonmarkAndSystemCombinations() {
        let noonmarkShortcut = GlobalQuickEntryShortcut(
            key: .f,
            modifiers: [.command, .shift]
        )
        let policy = GlobalQuickEntryShortcutPolicy()

        XCTAssertEqual(
            policy.validate(
                GlobalQuickEntryShortcut(
                    key: .n,
                    modifiers: [.shift]
                ),
                noonmarkShortcutSnapshot: .available([
                    noonmarkShortcut
                ]),
                systemShortcutSnapshot: .available([])
            ),
            .unsafeModifierCombination
        )
        XCTAssertEqual(
            policy.validate(
                noonmarkShortcut,
                noonmarkShortcutSnapshot: .available([
                    noonmarkShortcut
                ]),
                systemShortcutSnapshot: .available([])
            ),
            .noonmarkCommandConflict
        )

        let systemShortcut = GlobalQuickEntryShortcut(
            key: .space,
            modifiers: [.command, .control]
        )
        XCTAssertEqual(
            policy.validate(
                systemShortcut,
                noonmarkShortcutSnapshot: .available([
                    noonmarkShortcut
                ]),
                systemShortcutSnapshot: .available([systemShortcut])
            ),
            .systemShortcutConflict
        )
        XCTAssertEqual(
            policy.validate(
                .standard,
                noonmarkShortcutSnapshot: .available([
                    noonmarkShortcut
                ]),
                systemShortcutSnapshot: .available([])
            ),
            .allowed
        )
    }

    func testPolicyFailsClosedWhenNoonmarkShortcutInspectionIsUnavailable() {
        let policy = GlobalQuickEntryShortcutPolicy()

        XCTAssertEqual(
            policy.validate(
                .standard,
                noonmarkShortcutSnapshot: .unavailable,
                systemShortcutSnapshot: .available([])
            ),
            .conflictInspectionUnavailable
        )
    }

    func testPolicyFailsClosedWhenSystemShortcutInspectionIsUnavailable() {
        let policy = GlobalQuickEntryShortcutPolicy()

        XCTAssertEqual(
            policy.validate(
                .standard,
                noonmarkShortcutSnapshot: .available([]),
                systemShortcutSnapshot: .unavailable
            ),
            .conflictInspectionUnavailable
        )
    }

    func testCoordinatorRegistersBeforePersistingAndRetainsOldBindingOnFailure() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )
        let registrar = FakeGlobalShortcutRegistrar()
        let coordinator = GlobalQuickEntryShortcutCoordinator(
            repository: repository,
            registrar: registrar,
            noonmarkShortcutSnapshot: { .available([]) },
            systemShortcutSnapshot: { .available([]) },
            onTrigger: {}
        )

        coordinator.start()

        XCTAssertEqual(registrar.registeredShortcut, .standard)
        XCTAssertEqual(coordinator.status, .active)

        let candidate = GlobalQuickEntryShortcutPreference(
            isEnabled: true,
            shortcut: GlobalQuickEntryShortcut(
                key: .k,
                modifiers: [.command, .option]
            )
        )
        registrar.nextRegistrationSucceeds = false
        coordinator.apply(candidate)

        XCTAssertEqual(registrar.registeredShortcut, .standard)
        XCTAssertEqual(repository.load(), .standard)
        XCTAssertEqual(
            coordinator.status,
            .registrationFailed(retainedShortcut: .standard)
        )
    }

    func testCoordinatorRejectsConflictWithoutTouchingRegistrationOrStorage() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )
        let registrar = FakeGlobalShortcutRegistrar()
        let systemShortcut = GlobalQuickEntryShortcut(
            key: .space,
            modifiers: [.command, .control]
        )
        let coordinator = GlobalQuickEntryShortcutCoordinator(
            repository: repository,
            registrar: registrar,
            noonmarkShortcutSnapshot: { .available([]) },
            systemShortcutSnapshot: {
                .available([systemShortcut])
            },
            onTrigger: {}
        )
        coordinator.start()

        coordinator.apply(
            GlobalQuickEntryShortcutPreference(
                isEnabled: true,
                shortcut: systemShortcut
            )
        )

        XCTAssertEqual(registrar.registrationAttempts, [.standard])
        XCTAssertEqual(registrar.registeredShortcut, .standard)
        XCTAssertEqual(repository.load(), .standard)
        XCTAssertEqual(
            coordinator.status,
            .validationFailed(
                reason: .systemShortcutConflict,
                retainedShortcut: .standard
            )
        )
    }

    func testCoordinatorFailsClosedWhenSystemInspectionIsUnavailable() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )
        let registrar = FakeGlobalShortcutRegistrar()
        let coordinator = GlobalQuickEntryShortcutCoordinator(
            repository: repository,
            registrar: registrar,
            noonmarkShortcutSnapshot: { .available([]) },
            systemShortcutSnapshot: { .unavailable },
            onTrigger: {}
        )

        coordinator.start()

        XCTAssertTrue(registrar.registrationAttempts.isEmpty)
        XCTAssertNil(registrar.registeredShortcut)
        XCTAssertEqual(repository.load(), .standard)
        XCTAssertEqual(
            coordinator.status,
            .validationFailed(
                reason: .conflictInspectionUnavailable,
                retainedShortcut: nil
            )
        )
    }

    func testDisablingUnregistersAndPersistsTheDisabledPreference() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )
        let registrar = FakeGlobalShortcutRegistrar()
        let coordinator = GlobalQuickEntryShortcutCoordinator(
            repository: repository,
            registrar: registrar,
            noonmarkShortcutSnapshot: { .available([]) },
            systemShortcutSnapshot: { .available([]) },
            onTrigger: {}
        )
        coordinator.start()

        let disabled = GlobalQuickEntryShortcutPreference(
            isEnabled: false,
            shortcut: .standard
        )
        coordinator.apply(disabled)

        XCTAssertNil(registrar.registeredShortcut)
        XCTAssertEqual(repository.load(), disabled)
        XCTAssertEqual(coordinator.status, .disabled)
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "GlobalQuickEntryShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}

@MainActor
private final class FakeGlobalShortcutRegistrar: GlobalQuickEntryShortcutRegistering {
    var registeredShortcut: GlobalQuickEntryShortcut?
    var registrationAttempts: [GlobalQuickEntryShortcut] = []
    var nextRegistrationSucceeds = true

    func register(
        _ shortcut: GlobalQuickEntryShortcut,
        onTrigger _: @escaping @MainActor () -> Void
    ) -> Bool {
        registrationAttempts.append(shortcut)
        guard nextRegistrationSucceeds else { return false }
        registeredShortcut = shortcut
        return true
    }

    func unregister() {
        registeredShortcut = nil
    }
}
