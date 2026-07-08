@testable import SuntraceAI
@testable import SuntraceCore
import XCTest

final class AISuggestionDraftApplierTests: XCTestCase {
    private let today = LocalDate("2026-07-05")
    private let tomorrow = LocalDate("2026-07-06")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfirmedAddSubtaskUsesCoreDomainInterface() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "整理原型差距", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)

        let operation = AIProposedOperation.addSubtask(traceID: traceID, title: "补截图验收", difficulty: .medium)
        let result = try AISuggestionDraftApplier().applyConfirmed(operation, to: engine, today: today, now: now)

        XCTAssertEqual(result.operation, operation)
        XCTAssertEqual(result.message, "已添加子任务")
        let subtasks = engine.subtasks.values.filter { $0.traceID == traceID }
        XCTAssertEqual(subtasks.count, 1)
        XCTAssertEqual(subtasks.first?.title, "补截图验收")
        XCTAssertEqual(subtasks.first?.difficulty, .medium)
    }

    func testConfirmedScheduleFromPoolCreatesPendingDayTrace() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "打包 DMG", now: now)

        _ = try AISuggestionDraftApplier().applyConfirmed(
            .scheduleFromPool(chainID: chainID, targetDate: tomorrow),
            to: engine,
            today: today,
            now: now
        )

        let scheduled = engine.futurePlans(today: today).first
        XCTAssertEqual(scheduled?.definition.title, "打包 DMG")
        XCTAssertEqual(scheduled?.trace.date, tomorrow)
        XCTAssertEqual(scheduled?.trace.status, .pending)
    }

    func testAssignLabelAppliesExistingActiveTagToPrimarySlot() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类任务", now: now)
        let tagID = try engine.createTaskTag(name: "工程", now: now)

        let result = try AISuggestionDraftApplier().applyConfirmed(
            .assignLabel(chainID: chainID, label: "工程"),
            to: engine,
            today: today,
            now: now
        )

        XCTAssertEqual(result.message, "已更新任务 Tag")
        XCTAssertEqual(engine.chains[chainID]?.tagAssignments, [TaskTagAssignment(tagID: tagID, slot: .tagI, now: now)])
    }

    func testAssignLabelFailsClosedWhenTagDoesNotExist() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类任务", now: now)

        XCTAssertThrowsError(
            try AISuggestionDraftApplier().applyConfirmed(
                .assignLabel(chainID: chainID, label: "工程"),
                to: engine,
                today: today,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? AISuggestionApplyError, .unsupportedOperation("tag 尚未创建或已停用"))
        }
    }
}
