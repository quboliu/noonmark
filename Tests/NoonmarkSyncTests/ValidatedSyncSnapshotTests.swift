import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class ValidatedSyncSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testPublicBoundaryRejectsDuplicateBaseIdentitiesWithoutTerminatingProcess() throws {
        let validSnapshot = try populatedSnapshot()
        let day = try XCTUnwrap(validSnapshot.days.first)
        let definition = try XCTUnwrap(validSnapshot.definitions.first)
        let trace = try XCTUnwrap(validSnapshot.traces.first)
        let invalidSnapshots: [(String, NoonmarkSnapshot)] = [
            (
                "duplicate Day",
                replacing(validSnapshot, days: validSnapshot.days + [day])
            ),
            (
                "duplicate task definition",
                replacing(
                    validSnapshot,
                    definitions: validSnapshot.definitions + [definition]
                )
            ),
            (
                "duplicate day trace",
                replacing(validSnapshot, traces: validSnapshot.traces + [trace])
            )
        ]

        for (name, invalidSnapshot) in invalidSnapshots {
            XCTAssertThrowsError(
                try ValidatedSyncSnapshot(invalidSnapshot),
                name
            ) { error in
                guard case .invalidInput = error as? NoonmarkError else {
                    return XCTFail("\(name) returned a non-domain error: \(error)")
                }
            }
            XCTAssertThrowsError(
                try SyncRecordMerger().merge(
                    records: [],
                    into: invalidSnapshot
                ),
                "the internal raw seam must reject \(name) before indexing"
            ) { error in
                guard case .invalidInput = error as? NoonmarkError else {
                    return XCTFail("raw \(name) returned a non-domain error: \(error)")
                }
            }
            XCTAssertNoThrow(
                try ValidatedSyncSnapshot(validSnapshot),
                "the process must remain alive after rejecting \(name)"
            )
        }
    }

    func testValidatedPublicMergePreservesLegalMergeBehavior() throws {
        let sourceSnapshot = try populatedSnapshot()
        let records = try SyncRecordMapper().records(
            from: sourceSnapshot,
            modifiedBy: SyncDeviceID("remote-mac")
        )
        let base = try ValidatedSyncSnapshot(NoonmarkEngine().snapshot())

        let result = SyncRecordMerger().merge(
            records: records,
            into: base,
            detectedAt: now.addingTimeInterval(1)
        )

        XCTAssertEqual(result.snapshot, sourceSnapshot)
        XCTAssertEqual(result.appliedRecordIDs.count, records.count)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    private func populatedSnapshot() throws -> NoonmarkSnapshot {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "Validated snapshot seam",
            now: now
        )
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.updateTheme(
            .warmPaper,
            writerID: "remote-mac",
            now: now.addingTimeInterval(2)
        )
        return engine.snapshot()
    }

    private func replacing(
        _ snapshot: NoonmarkSnapshot,
        days: [Day]? = nil,
        definitions: [TaskDefinition]? = nil,
        traces: [DayTrace]? = nil
    ) -> NoonmarkSnapshot {
        NoonmarkSnapshot(
            days: days ?? snapshot.days,
            chains: snapshot.chains,
            definitions: definitions ?? snapshot.definitions,
            traces: traces ?? snapshot.traces,
            subtasks: snapshot.subtasks,
            preferences: snapshot.preferences,
            classifications: snapshot.classifications
        )
    }
}
