import Foundation
import NoonmarkMacRuntime
import XCTest

@MainActor
final class InputDraftFlushCoordinatorTests: XCTestCase {
    func testFlushesEveryRegisteredDraftInStableOwnerOrder() async {
        let coordinator = InputDraftFlushCoordinator()
        var flushed: [String] = []

        coordinator.register(
            ownerID: "task:z:title",
            token: UUID()
        ) {
            flushed.append("z")
            return true
        }
        coordinator.register(
            ownerID: "task:a:description",
            token: UUID()
        ) {
            flushed.append("a")
            return false
        }

        let succeeded = await coordinator.flushAll()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(flushed, ["a", "z"])
        XCTAssertEqual(
            coordinator.lastFailedOwnerIDs,
            ["task:a:description"]
        )
    }

    func testStaleUnregisterCannotRemoveReplacementRegistration() async {
        let coordinator = InputDraftFlushCoordinator()
        let staleToken = UUID()
        let currentToken = UUID()
        var currentWasFlushed = false

        coordinator.register(
            ownerID: "review:today:summary",
            token: staleToken
        ) {
            XCTFail("stale registration must be replaced")
            return false
        }
        coordinator.register(
            ownerID: "review:today:summary",
            token: currentToken
        ) {
            currentWasFlushed = true
            return true
        }
        coordinator.unregister(
            ownerID: "review:today:summary",
            token: staleToken
        )

        XCTAssertEqual(
            coordinator.registeredOwnerIDs,
            ["review:today:summary"]
        )
        let succeeded = await coordinator.flushAll()
        XCTAssertTrue(succeeded)
        XCTAssertTrue(currentWasFlushed)
        XCTAssertTrue(coordinator.lastFailedOwnerIDs.isEmpty)
    }

    func testCurrentRegistrationCanBeRemoved() async {
        let coordinator = InputDraftFlushCoordinator()
        let token = UUID()

        coordinator.register(
            ownerID: "task:one:title",
            token: token
        ) {
            XCTFail("removed registration must not flush")
            return false
        }
        coordinator.unregister(
            ownerID: "task:one:title",
            token: token
        )

        XCTAssertTrue(coordinator.registeredOwnerIDs.isEmpty)
        let succeeded = await coordinator.flushAll()
        XCTAssertTrue(succeeded)
    }
}
