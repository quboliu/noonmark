import NoonmarkMacRuntime
import XCTest

final class IMETextDraftAutosaveGateTests: XCTestCase {
    func testMarkedTextRemainsNativeUntilCompositionEnds() {
        XCTAssertFalse(
            IMETextBindingPublicationPolicy
                .shouldPublishToSwiftUI(
                    isComposing: true,
                    defersMarkedTextUpdates: true
                )
        )
        XCTAssertTrue(
            IMETextBindingPublicationPolicy
                .shouldPublishToSwiftUI(
                    isComposing: false,
                    defersMarkedTextUpdates: true
                )
        )
        XCTAssertTrue(
            IMETextBindingPublicationPolicy
                .shouldPublishToSwiftUI(
                    isComposing: true,
                    defersMarkedTextUpdates: false
                )
        )
    }

    func testOrdinaryDraftPersistsOnlyAfterMatchingSuccessAck() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:title")

        let schedule = try XCTUnwrap(gate.draftDidChange())
        let request = try XCTUnwrap(
            gate.beginPersistence(for: schedule)
        )

        XCTAssertTrue(gate.hasUnflushedChanges)
        XCTAssertNil(gate.persistenceDidSucceed(request))
        XCTAssertFalse(gate.hasUnflushedChanges)
    }

    func testCompositionInvalidatesTimerAndPersistsOnlyFinalRevision() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:title")
        let staleSchedule = try XCTUnwrap(gate.draftDidChange())

        XCTAssertNil(
            gate.nativeSnapshotDidChange(
                textChanged: true,
                isComposing: true
            )
        )
        XCTAssertFalse(gate.permitsAutosave(staleSchedule))
        XCTAssertNil(
            gate.nativeSnapshotDidChange(
                textChanged: true,
                isComposing: true
            )
        )

        let finalSchedule = try XCTUnwrap(
            gate.nativeSnapshotDidChange(
                textChanged: true,
                isComposing: false
            )
        )

        XCTAssertTrue(gate.permitsAutosave(finalSchedule))
        XCTAssertEqual(finalSchedule.revision, 4)
    }

    func testExplicitFlushWaitsForCompositionFinalization() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "review:day:summary")
        _ = gate.compositionDidChange(isActive: true)
        _ = gate.draftDidChange()

        XCTAssertNil(gate.requestFlush())

        let schedule = try XCTUnwrap(
            gate.compositionDidChange(isActive: false)
        )
        XCTAssertEqual(schedule.delayMilliseconds, 0)
    }

    func testCompositionTransitionInvalidatesSameRevisionSchedule()
        throws
    {
        var gate = IMETextDraftAutosaveGate(
            ownerID: "review:day:summary"
        )
        let beforeComposition = try XCTUnwrap(
            gate.draftDidChange()
        )

        XCTAssertNil(
            gate.compositionDidChange(isActive: true)
        )
        let afterComposition = try XCTUnwrap(
            gate.compositionDidChange(isActive: false)
        )

        XCTAssertFalse(
            gate.permitsAutosave(beforeComposition)
        )
        XCTAssertTrue(
            gate.permitsAutosave(afterComposition)
        )
        XCTAssertEqual(
            beforeComposition.revision,
            afterComposition.revision
        )
    }

    func testLaterInputMakesOlderScheduleAndAckUnableToClearDirty() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:body")
        let firstSchedule = try XCTUnwrap(gate.draftDidChange())
        let firstRequest = try XCTUnwrap(
            gate.beginPersistence(for: firstSchedule)
        )
        _ = gate.draftDidChange()

        let nextSchedule = try XCTUnwrap(
            gate.persistenceDidSucceed(firstRequest)
        )

        XCTAssertTrue(gate.hasUnflushedChanges)
        XCTAssertTrue(gate.permitsAutosave(nextSchedule))
    }

    func testFailureKeepsDirtyAndSchedulesBoundedRetry() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:body")
        let schedule = try XCTUnwrap(gate.draftDidChange())
        let request = try XCTUnwrap(
            gate.beginPersistence(for: schedule)
        )

        let retry = try XCTUnwrap(
            gate.persistenceDidFail(request)
        )

        XCTAssertTrue(gate.hasUnflushedChanges)
        XCTAssertEqual(retry.delayMilliseconds, 1000)
        XCTAssertTrue(gate.permitsAutosave(retry))
    }

    func testWrongOwnerOrGenerationAckIsIgnored() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:title")
        let schedule = try XCTUnwrap(gate.draftDidChange())
        let request = try XCTUnwrap(
            gate.beginPersistence(for: schedule)
        )
        let wrongOwner = IMETextDraftAutosaveGate.PersistenceRequest(
            ownerID: "task:two:title",
            generation: request.generation,
            revision: request.revision,
            requestID: request.requestID
        )

        XCTAssertNil(gate.persistenceDidSucceed(wrongOwner))
        XCTAssertTrue(gate.hasUnflushedChanges)

        gate.discardLocalChanges()
        XCTAssertNil(gate.persistenceDidSucceed(request))
        XCTAssertFalse(gate.hasUnflushedChanges)
    }

    func testDuplicateEndEditingAndDisappearCannotPersistTwice() throws {
        var gate = IMETextDraftAutosaveGate(ownerID: "task:one:title")
        _ = gate.draftDidChange()
        let first = try XCTUnwrap(gate.requestFlush())
        let request = try XCTUnwrap(gate.beginPersistence(for: first))

        XCTAssertNil(gate.requestFlush())
        XCTAssertNil(gate.persistenceDidSucceed(request))
        XCTAssertNil(gate.requestFlush())
    }
}
