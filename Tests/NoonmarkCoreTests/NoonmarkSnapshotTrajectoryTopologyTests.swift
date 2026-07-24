@testable import NoonmarkCore
import XCTest

final class NoonmarkSnapshotTrajectoryTopologyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_735_689_600)
    private let yesterday = LocalDate("2024-12-31")
    private let today = LocalDate("2025-01-01")
    private let tomorrow = LocalDate("2025-01-02")

    func testTraceContinuationRejectsCrossChainStatusSequenceDateAndForkFacts() throws {
        let fixture = try continuationFixture(includeSubtask: false)
        let sourceIndex = try XCTUnwrap(
            fixture.snapshot.traces.firstIndex { $0.id == fixture.sourceTraceID }
        )
        let targetIndex = try XCTUnwrap(
            fixture.snapshot.traces.firstIndex { $0.id == fixture.targetTraceID }
        )

        var crossChain = fixture.snapshot
        crossChain.traces[targetIndex].chainID = fixture.otherChainID
        crossChain.traces[targetIndex].definitionID = fixture.otherDefinitionID

        var invalidSourceStatus = fixture.snapshot
        invalidSourceStatus.traces[sourceIndex].status = .pending

        var invalidSequence = fixture.snapshot
        invalidSequence.traces[targetIndex].continuationSeq =
            invalidSequence.traces[sourceIndex].continuationSeq + 1

        var invalidDate = fixture.snapshot
        invalidDate.days.append(Day(date: yesterday, now: base))
        invalidDate.traces[targetIndex].date = yesterday

        var fork = fixture.snapshot
        var secondTarget = fork.traces[targetIndex]
        secondTarget.id = DayTraceID(
            UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        )
        secondTarget.status = .unfinished
        secondTarget.priority += 1
        secondTarget.settledAt = secondTarget.contentUpdatedAt
        fork.traces.append(secondTarget)

        for candidate in [
            crossChain,
            invalidSourceStatus,
            invalidSequence,
            invalidDate,
            fork
        ] {
            XCTAssertThrowsError(try candidate.validateIntegrity())
        }
    }

    func testChangedReplacementMayCrossChainButRejectsWrongSourceDateAndSelfLink() throws {
        let engine = NoonmarkEngine()
        let sourceChainID = try engine.createPoolTask(
            title: "原任务",
            now: base
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let targetTraceID = try engine.changeTrace(
            traceID: sourceTraceID,
            newTitle: "替换任务",
            today: today,
            now: base.addingTimeInterval(2)
        )
        let valid = engine.snapshot()
        XCTAssertNoThrow(try valid.validateIntegrity())
        XCTAssertNotEqual(
            valid.traces.first { $0.id == sourceTraceID }?.chainID,
            valid.traces.first { $0.id == targetTraceID }?.chainID
        )

        let sourceIndex = try XCTUnwrap(
            valid.traces.firstIndex { $0.id == sourceTraceID }
        )
        let targetIndex = try XCTUnwrap(
            valid.traces.firstIndex { $0.id == targetTraceID }
        )

        var wrongSourceStatus = valid
        wrongSourceStatus.traces[sourceIndex].status = .returnedToPool

        var wrongDate = valid
        wrongDate.days.append(
            Day(date: tomorrow, now: base.addingTimeInterval(2))
        )
        wrongDate.traces[targetIndex].date = tomorrow

        var selfLink = valid
        selfLink.traces[sourceIndex].changedToTraceID = sourceTraceID

        for candidate in [wrongSourceStatus, wrongDate, selfLink] {
            XCTAssertThrowsError(try candidate.validateIntegrity())
        }
    }

    func testSubtaskContinuationRejectsSelfCycleForkLineageParentAndSourceStatusFacts() throws {
        let fixture = try continuationFixture(includeSubtask: true)
        let sourceIndex = try XCTUnwrap(
            fixture.snapshot.subtasks.firstIndex {
                $0.id == fixture.sourceSubtaskID
            }
        )
        let targetIndex = try XCTUnwrap(
            fixture.snapshot.subtasks.firstIndex {
                $0.id == fixture.targetSubtaskID
            }
        )

        var selfLink = fixture.snapshot
        selfLink.subtasks[targetIndex].carriedFromSubtaskID =
            fixture.targetSubtaskID

        var cycle = fixture.snapshot
        cycle.subtasks[sourceIndex].carriedFromSubtaskID =
            fixture.targetSubtaskID

        var fork = fixture.snapshot
        var secondTarget = fork.subtasks[targetIndex]
        secondTarget.id = SubtaskID(
            UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
        )
        secondTarget.position += 1
        fork.subtasks.append(secondTarget)

        var wrongLineage = fixture.snapshot
        wrongLineage.subtasks[targetIndex].lineageID = SubtaskLineageID()

        var wrongParentTrace = fixture.snapshot
        wrongParentTrace.subtasks[targetIndex].traceID =
            fixture.sourceTraceID

        var wrongSourceStatus = fixture.snapshot
        wrongSourceStatus.subtasks[sourceIndex].status = .pending

        for candidate in [
            selfLink,
            cycle,
            fork,
            wrongLineage,
            wrongParentTrace,
            wrongSourceStatus
        ] {
            XCTAssertThrowsError(try candidate.validateIntegrity())
        }
    }

    func testCancelledContinuationTargetRetainsSourceLinksButCancelledSourceCannotBeReferenced() throws {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销延续拓扑",
            now: base
        )
        let sourceTraceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let sourceSubtaskID = try current.addSubtask(
            traceID: sourceTraceID,
            title: "保留 lineage",
            now: base.addingTimeInterval(2)
        )
        let before = current.snapshot()
        let targetTraceID = try current.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: base.addingTimeInterval(3)
        )
        let forward = current.snapshot()
        let targetSubtaskID = try XCTUnwrap(
            current.subtasks.values.first { $0.traceID == targetTraceID }?.id
        )
        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(4)
        )
        let validCancelledTarget = undone.snapshot()

        XCTAssertEqual(
            validCancelledTarget.traces.first { $0.id == targetTraceID }?
                .carriedFromTraceID,
            sourceTraceID
        )
        XCTAssertEqual(
            validCancelledTarget.subtasks.first { $0.id == targetSubtaskID }?
                .carriedFromSubtaskID,
            sourceSubtaskID
        )
        XCTAssertNoThrow(try validCancelledTarget.validateIntegrity())

        var cancelledSource = forward
        let sourceIndex = try XCTUnwrap(
            cancelledSource.traces.firstIndex { $0.id == sourceTraceID }
        )
        let cancellationID = UUID(
            uuidString: "A3000000-0000-0000-0000-000000000001"
        )!
        cancelledSource.traces[sourceIndex].status = .cancelledDraft
        cancelledSource.traces[sourceIndex].draftCancellationID = cancellationID
        cancelledSource.traces[sourceIndex].draftCancelledOn = today
        cancelledSource.traces[sourceIndex].settledAt =
            cancelledSource.traces[sourceIndex].contentUpdatedAt

        XCTAssertThrowsError(try cancelledSource.validateIntegrity())
    }

    func testTraceStatusProgressActiveAndPriorityFactsFailClosed() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(
            title: "第一条 active",
            now: base
        )
        let firstTraceID = try engine.scheduleFromPool(
            chainID: firstChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let secondChainID = try engine.createPoolTask(
            title: "第二个 priority slot",
            now: base
        )
        let secondTraceID = try engine.scheduleFromPool(
            chainID: secondChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let baseline = engine.snapshot()
        let firstIndex = try XCTUnwrap(
            baseline.traces.firstIndex { $0.id == firstTraceID }
        )
        let secondIndex = try XCTUnwrap(
            baseline.traces.firstIndex { $0.id == secondTraceID }
        )

        var pendingWithCompletion = baseline
        pendingWithCompletion.traces[firstIndex].completedAt =
            base.addingTimeInterval(1)

        var completedWithoutCompletion = baseline
        completedWithoutCompletion.traces[firstIndex].status = .completed

        var unfinishedWithoutSettlement = baseline
        unfinishedWithoutSettlement.traces[firstIndex].status = .unfinished

        var invalidProgress = baseline
        invalidProgress.traces[firstIndex].manualProgressPercent = 101

        var duplicateActive = baseline
        var secondActive = duplicateActive.traces[firstIndex]
        secondActive.id = DayTraceID(
            UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!
        )
        secondActive.priority = 99
        duplicateActive.traces.append(secondActive)

        var duplicatePriority = baseline
        duplicatePriority.traces[secondIndex].priority =
            duplicatePriority.traces[firstIndex].priority

        for candidate in [
            pendingWithCompletion,
            completedWithoutCompletion,
            unfinishedWithoutSettlement,
            invalidProgress,
            duplicateActive,
            duplicatePriority
        ] {
            XCTAssertThrowsError(try candidate.validateIntegrity())
        }

        var restoredPendingWitness = baseline
        restoredPendingWitness.traces[firstIndex].draftCancellationID = UUID(
            uuidString: "A4000000-0000-0000-0000-000000000002"
        )!
        XCTAssertNoThrow(try restoredPendingWitness.validateIntegrity())
    }

    private func continuationFixture(
        includeSubtask: Bool
    ) throws -> (
        snapshot: NoonmarkSnapshot,
        sourceTraceID: DayTraceID,
        targetTraceID: DayTraceID,
        sourceSubtaskID: SubtaskID?,
        targetSubtaskID: SubtaskID?,
        otherChainID: TaskChainID,
        otherDefinitionID: TaskDefinitionID
    ) {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "延续拓扑",
            now: base
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let sourceSubtaskID: SubtaskID? = if includeSubtask {
            try engine.addSubtask(
                traceID: sourceTraceID,
                title: "延续子任务",
                now: base.addingTimeInterval(2)
            )
        } else {
            nil
        }
        let targetTraceID = try engine.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: base.addingTimeInterval(3)
        )
        let targetSubtaskID = engine.subtasks.values.first {
            $0.traceID == targetTraceID
        }?.id
        let otherChainID = try engine.createPoolTask(
            title: "另一条链",
            now: base.addingTimeInterval(4)
        )
        let otherDefinitionID = try XCTUnwrap(
            engine.definitions.values.first {
                $0.chainID == otherChainID
            }?.id
        )
        return (
            engine.snapshot(),
            sourceTraceID,
            targetTraceID,
            sourceSubtaskID,
            targetSubtaskID,
            otherChainID,
            otherDefinitionID
        )
    }
}
