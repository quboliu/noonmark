import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class WorkspaceStateRepositoryTests: XCTestCase {
    func testRoundTripsExpansionState() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = WorkspaceStateRepository(defaults: defaults)
        XCTAssertFalse(repository.containsSavedState)
        let expected = WorkspaceState(
            sidebarExpanded: false,
            detailExpanded: true,
            usesCustomDetailWidth: true,
            expandedSidebarWidth: 264,
            customDetailWidth: 336
        )

        repository.save(expected)

        XCTAssertTrue(repository.containsSavedState)
        XCTAssertEqual(repository.load(), expected)
    }

    func testIncompleteExpansionStateFailsClosedToCurrentDefault() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = WorkspaceStateRepository(defaults: defaults)
        let incompleteData = Data(
            """
            {
              "sidebarExpanded": false,
              "detailExpanded": true,
              "usesCustomDetailWidth": true
            }
            """.utf8
        )
        defaults.set(
            incompleteData,
            forKey: WorkspaceStateRepository.defaultStorageKey
        )

        XCTAssertTrue(repository.containsSavedState)
        XCTAssertEqual(repository.load(), .defaultValue)
    }

    func testMissingOrCorruptValueUsesDeterministicDefault() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = WorkspaceStateRepository(defaults: defaults)
        XCTAssertEqual(repository.load(), .defaultValue)

        defaults.set(Data("not-json".utf8), forKey: WorkspaceStateRepository.defaultStorageKey)
        XCTAssertEqual(repository.load(), .defaultValue)
    }

    func testDisabledRepositoryNeitherLoadsNorWritesSharedDefaults() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enabled = WorkspaceStateRepository(defaults: defaults)
        enabled.save(
            WorkspaceState(
                sidebarExpanded: false,
                detailExpanded: true
            )
        )
        let disabled = WorkspaceStateRepository(
            defaults: defaults,
            persistenceEnabled: false
        )

        XCTAssertEqual(disabled.load(), .defaultValue)
        disabled.save(
            WorkspaceState(
                sidebarExpanded: true,
                detailExpanded: false
            )
        )

        XCTAssertFalse(enabled.load().sidebarExpanded)
        XCTAssertTrue(enabled.load().detailExpanded)
    }

    func testResetRestoresDefaultState() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = WorkspaceStateRepository(defaults: defaults)
        repository.save(
            WorkspaceState(
                sidebarExpanded: false,
                detailExpanded: true
            )
        )

        repository.reset()

        XCTAssertEqual(repository.load(), .defaultValue)
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "WorkspaceStateRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
