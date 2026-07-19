@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncCanonicalizationBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_345_678.125)

    func testValidAndMalformedSameIDVariantsFailAtomicallyWithoutApplyingEither() throws {
        let original = NoonmarkEngine().snapshot()
        let valid = try SyncRecordMapper().record(
            for: Day(date: LocalDate("2026-07-16"), now: now),
            modifiedBy: SyncDeviceID("valid-day")
        )
        var malformed = valid
        malformed.modifiedAt = now.addingTimeInterval(1)
        XCTAssertEqual(valid.id, malformed.id)
        XCTAssertFalse(valid.exactlyMatches(malformed))

        let result = try SyncRecordMerger().merge(
            records: [malformed, valid],
            into: original,
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.snapshot, original)
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(Set(result.conflicts.map(\.id)).count, 2)
        for record in [valid, malformed] {
            XCTAssertTrue(
                result.conflicts.contains {
                    $0.remoteRecord.exactlyMatches(record)
                }
            )
        }
    }

    func testMultipleCurrentDefinitionsAreConflictsRatherThanPermanentWaiting() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "多个 current definition",
            now: now
        )
        let chain = try XCTUnwrap(source.chains[chainID])
        let first = try XCTUnwrap(
            source.definitions.values.first { $0.chainID == chainID }
        )
        let second = TaskDefinition(
            chainID: chainID,
            sequence: 2,
            title: "并发 current definition",
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let records = try [
            mapper.record(
                for: chain,
                modifiedBy: SyncDeviceID("chain-device")
            ),
            mapper.record(
                for: first,
                modifiedBy: SyncDeviceID("definition-first")
            ),
            mapper.record(
                for: second,
                modifiedBy: SyncDeviceID("definition-second")
            )
        ]
        let original = NoonmarkEngine().snapshot()

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: original,
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.snapshot, original)
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, records.count)
        XCTAssertEqual(
            Set(result.conflicts.map(\.remoteRecordID)),
            Set(records.map(\.id))
        )
        XCTAssertEqual(Set(result.conflicts.map(\.type)), [.invalidRecordPayload])
    }

    func testComponentWithoutDayWaitsAtomicallyInsteadOfPartiallyCommitting() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "等待稳定 Day identity",
            now: now
        )
        let date = LocalDate("2026-07-16")
        let traceID = try source.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now.addingTimeInterval(1)
        )
        let snapshot = source.snapshot()
        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: try XCTUnwrap(snapshot.chains.first),
            modifiedBy: SyncDeviceID("chain-device")
        )
        let definitionRecord = try mapper.record(
            for: try XCTUnwrap(snapshot.definitions.first),
            modifiedBy: SyncDeviceID("definition-device")
        )
        let traceRecord = try mapper.record(
            for: try XCTUnwrap(snapshot.traces.first),
            modifiedBy: SyncDeviceID("trace-device")
        )
        let dayRecord = try mapper.record(
            for: try XCTUnwrap(snapshot.days.first),
            modifiedBy: SyncDeviceID("day-device")
        )
        let original = NoonmarkEngine().snapshot()
        let merger = SyncRecordMerger(mapper: mapper)
        let incompleteRecords = [
            traceRecord,
            definitionRecord,
            chainRecord
        ]

        let first = try merger.merge(
            records: incompleteRecords,
            into: original,
            detectedAt: now.addingTimeInterval(2)
        )
        let second = try merger.merge(
            records: incompleteRecords.reversed(),
            into: original,
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshot, original)
        XCTAssertTrue(first.appliedRecordIDs.isEmpty)
        XCTAssertEqual(
            Set(first.waitingRecords.map(\.remoteRecordID)),
            Set(incompleteRecords.map(\.id))
        )
        XCTAssertEqual(
            first.waitingRecords.map(\.dependencies),
            Array(repeating: [.day(date)], count: incompleteRecords.count)
        )
        XCTAssertTrue(first.conflicts.isEmpty)

        let completed = try merger.merge(
            records: incompleteRecords + [dayRecord],
            into: original,
            detectedAt: now.addingTimeInterval(3)
        )
        XCTAssertTrue(completed.waitingRecords.isEmpty)
        XCTAssertTrue(completed.conflicts.isEmpty)
        XCTAssertEqual(
            completed.snapshot.days.first?.id,
            snapshot.days.first?.id
        )
        XCTAssertEqual(
            completed.snapshot.traces.first?.id,
            traceID
        )
        XCTAssertEqual(
            Set(completed.appliedRecordIDs),
            Set(incompleteRecords.map(\.id) + [dayRecord.id])
        )
        XCTAssertNoThrow(try completed.snapshot.validateIntegrity())
    }
}
