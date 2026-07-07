@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncRecordMergerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")
    private let tomorrow = LocalDate("2026-07-06")

    func testTwoDeviceSyncAppliesNewRecordsThroughGenericTransport() async throws {
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "从 Mac 同步到 iPhone", descriptionText: "通用底座记录。", note: nil, now: now)
        let traceID = try source.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try source.addSubtask(traceID: traceID, title: "写 mock transport 测试", difficulty: .hard, now: now)

        let mapper = SyncRecordMapper()
        let transport = InMemorySyncTransport()
        try await transport.push(try mapper.records(from: source.snapshot(), modifiedBy: SyncDeviceID("mac-a")))

        let target = SuntraceEngine()
        let result = await SyncRecordMerger(mapper: mapper).merge(records: try transport.fetchAll(), into: target.snapshot(), detectedAt: now)
        let restored = SuntraceEngine(snapshot: result.snapshot)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertFalse(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        XCTAssertEqual(restored.getDayTodo(date: today).traces.first?.id, traceID)
    }

    func testHistoricalTraceMutationFailsClosed() throws {
        let local = SuntraceEngine()
        let chainID = try local.createPoolTask(title: "历史不可改写", now: now)
        let traceID = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try local.markCompleted(traceID: traceID, today: today, now: now)

        var remoteTrace = try XCTUnwrap(local.snapshot().traces.first)
        remoteTrace.status = .pending
        remoteTrace.completedAt = nil

        let mapper = SyncRecordMapper()
        let remoteRecord = try mapper.record(for: remoteTrace, modifiedBy: SyncDeviceID("iphone-b"))
        let result = SyncRecordMerger(mapper: mapper).merge(records: [remoteRecord], into: local.snapshot(), detectedAt: now)

        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(result.snapshot, local.snapshot())
    }

    func testMissingParentTraceFailsClosedForSubtask() throws {
        let orphan = Subtask(
            traceID: DayTraceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            title: "孤儿子任务",
            position: 0,
            now: now
        )

        let mapper = SyncRecordMapper()
        let record = try mapper.record(for: orphan, modifiedBy: SyncDeviceID("iphone-b"))
        let result = SyncRecordMerger(mapper: mapper).merge(records: [record], into: SuntraceEngine().snapshot(), detectedAt: now)

        XCTAssertEqual(result.conflicts.map(\.type), [.missingParent])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }

    func testDuplicateActiveTraceFailsClosed() throws {
        let local = SuntraceEngine()
        let chainID = try local.createPoolTask(title: "同一任务链只能一个活跃轨迹", now: now)
        let definitionID = try XCTUnwrap(local.snapshot().definitions.first?.id)
        _ = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let secondTrace = DayTrace(
            chainID: chainID,
            definitionID: definitionID,
            date: tomorrow,
            priority: 0,
            now: now
        )

        let mapper = SyncRecordMapper()
        let record = try mapper.record(for: secondTrace, modifiedBy: SyncDeviceID("iphone-b"))
        let result = SyncRecordMerger(mapper: mapper).merge(records: [record], into: local.snapshot(), detectedAt: now)

        XCTAssertEqual(result.conflicts.map(\.type), [.duplicateActiveTrace])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }
}
