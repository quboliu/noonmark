import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class GlobalIdeaCaptureShortcutTests: XCTestCase {
    func testIdeaCaptureStandardPreferenceUsesControlShiftIAndFormatsIt() {
        let preference = GlobalQuickEntryShortcutPreference.ideaCaptureStandard

        XCTAssertTrue(preference.isEnabled)
        XCTAssertEqual(preference.shortcut.key, .i)
        XCTAssertEqual(preference.shortcut.modifiers, [.control, .shift])
        XCTAssertEqual(preference.shortcut.displayText, "⌃⇧I")
    }

    func testIdeaCaptureSlotPersistsIndependentlyOfQuickEntrySlot() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quickEntryRepository = GlobalShortcutPreferenceRepository(
            defaults: defaults
        )
        let ideaCaptureRepository = GlobalShortcutPreferenceRepository(
            defaults: defaults,
            storageKey: GlobalShortcutPreferenceRepository
                .defaultIdeaCaptureStorageKey,
            defaultPreference: .ideaCaptureStandard
        )

        XCTAssertEqual(quickEntryRepository.load(), .standard)
        XCTAssertEqual(ideaCaptureRepository.load(), .ideaCaptureStandard)

        let customized = GlobalQuickEntryShortcutPreference(
            isEnabled: true,
            shortcut: GlobalQuickEntryShortcut(
                key: .j,
                modifiers: [.command, .option]
            )
        )
        ideaCaptureRepository.save(customized)
        XCTAssertEqual(ideaCaptureRepository.load(), customized)
        XCTAssertEqual(quickEntryRepository.load(), .standard)

        defaults.set(
            Data("not-json".utf8),
            forKey: GlobalShortcutPreferenceRepository
                .defaultIdeaCaptureStorageKey
        )
        XCTAssertEqual(
            ideaCaptureRepository.load(),
            GlobalQuickEntryShortcutPreference(
                isEnabled: false,
                shortcut: .ideaCaptureStandard
            )
        )
        XCTAssertEqual(quickEntryRepository.load(), .standard)
    }

    func testIdeaCaptureCoordinatorRegistersItsOwnDefault() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = GlobalShortcutPreferenceRepository(
            defaults: defaults,
            storageKey: GlobalShortcutPreferenceRepository
                .defaultIdeaCaptureStorageKey,
            defaultPreference: .ideaCaptureStandard
        )
        let registrar = FakeIdeaCaptureShortcutRegistrar()
        let coordinator = GlobalIdeaCaptureShortcutCoordinator(
            repository: repository,
            registrar: registrar,
            noonmarkShortcutSnapshot: { .available([.standard]) },
            systemShortcutSnapshot: { .available([]) },
            onTrigger: {}
        )

        coordinator.start()

        XCTAssertEqual(registrar.registeredShortcut, .ideaCaptureStandard)
        XCTAssertEqual(coordinator.status, .active)
    }

    func testSiblingHotkeyReservedSnapshotRejectsIdenticalCombination() {
        let snapshot = GlobalShortcutSnapshot.available([])
            .insertingReserved(.standard)

        let policy = GlobalQuickEntryShortcutPolicy()
        XCTAssertEqual(
            policy.validate(
                .standard,
                noonmarkShortcutSnapshot: snapshot,
                systemShortcutSnapshot: .available([])
            ),
            .noonmarkCommandConflict
        )
        XCTAssertEqual(
            policy.validate(
                .ideaCaptureStandard,
                noonmarkShortcutSnapshot: snapshot,
                systemShortcutSnapshot: .available([])
            ),
            .allowed
        )
    }

    func testInsertingReservedKeepsUnavailableSnapshotFailClosed() {
        XCTAssertEqual(
            GlobalShortcutSnapshot.unavailable.insertingReserved(.standard),
            .unavailable
        )
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "GlobalIdeaCaptureShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}

@MainActor
private final class FakeIdeaCaptureShortcutRegistrar: GlobalQuickEntryShortcutRegistering {
    var registeredShortcut: GlobalQuickEntryShortcut?

    func register(
        _ shortcut: GlobalQuickEntryShortcut,
        onTrigger _: @escaping @MainActor () -> Void
    ) -> Bool {
        registeredShortcut = shortcut
        return true
    }

    func unregister() {
        registeredShortcut = nil
    }
}
