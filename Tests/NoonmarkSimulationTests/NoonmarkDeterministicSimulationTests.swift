@testable import NoonmarkCore
import XCTest

final class NoonmarkDeterministicSimulationTests: XCTestCase {
    private typealias SimulationOperation = (inout SimulationContext) throws -> Void

    private struct SimulationContext {
        let engine: NoonmarkEngine
        var rng: SeededGenerator
        var today: LocalDate
        var now: Date
        let iteration: Int
        var step: Int
    }

    func testSeededDomainOperationSimulation() throws {
        let baseSeed = UInt64(ProcessInfo.processInfo.environment["ST_SIM_SEED"] ?? "", radix: 10) ?? 0x5EED_2026
        let runs = Int(ProcessInfo.processInfo.environment["ST_SIM_RUNS"] ?? "") ?? 32
        let onlyIteration = ProcessInfo.processInfo.environment["ST_SIM_ITER"].flatMap(Int.init)
        let iterations = onlyIteration.map { [$0] } ?? Array(0..<runs)

        for iteration in iterations {
            let seed = mix(baseSeed &+ UInt64(iteration))
            XCTAssertNoThrow(
                try runSimulation(seed: seed, iteration: iteration),
                "replay with ST_SIM_SEED=\(baseSeed) ST_SIM_ITER=\(iteration)"
            )
        }
    }

    private func runSimulation(seed: UInt64, iteration: Int) throws {
        let operations = simulationOperations
        var context = SimulationContext(
            engine: NoonmarkEngine(),
            rng: SeededGenerator(seed: seed),
            today: LocalDate("2026-07-05"),
            now: Date(timeIntervalSince1970: 1_800_000_000 + Double(iteration * 10000)),
            iteration: iteration,
            step: 0
        )
        var events: [String] = []

        for step in 0..<140 {
            context.step = step
            context.now = context.now.addingTimeInterval(1)
            let action = context.rng.nextInt(operations.count)
            events.append("step=\(step) action=\(action) today=\(context.today)")

            do {
                try operations[action](&context)
            } catch {
                events.append("domain-reject=\(error)")
            }

            do {
                try assertInvariants(context.engine, today: context.today)
            } catch {
                XCTFail("simulation invariant failed seed=\(seed) iteration=\(iteration)\n\(events.joined(separator: "\n"))\n\(error)")
                throw error
            }
        }
    }

    private var simulationOperations: [SimulationOperation] {
        [
            createPoolTask,
            scheduleFromPool,
            addSubtask,
            completeSubtask,
            abandonSubtask,
            setManualProgress,
            markCompleted,
            returnToPool,
            rescheduleFuturePlan,
            advanceDay,
            continueTrace,
            changeTrace
        ]
    }

    private func createPoolTask(_ context: inout SimulationContext) throws {
        _ = try context.engine.createPoolTask(
            title: "seed-\(context.iteration)-task-\(context.step)",
            now: context.now
        )
    }

    private func scheduleFromPool(_ context: inout SimulationContext) throws {
        if let pool = context.engine.taskPool().first {
            _ = try context.engine.scheduleFromPool(
                chainID: pool.chain.id,
                date: offset(context.today, by: context.rng.nextInt(4)),
                today: context.today,
                now: context.now
            )
        }
    }

    private func addSubtask(_ context: inout SimulationContext) throws {
        if let trace = choosePendingTrace(context.engine, rng: &context.rng) {
            _ = try context.engine.addSubtask(
                traceID: trace.id,
                title: "sub-\(context.iteration)-\(context.step)",
                difficulty: SubtaskDifficulty.allCases[context.rng.nextInt(SubtaskDifficulty.allCases.count)],
                now: context.now
            )
        }
    }

    private func completeSubtask(_ context: inout SimulationContext) throws {
        if let subtask = chooseCurrentPendingSubtask(context.engine, today: context.today, rng: &context.rng) {
            try context.engine.completeSubtask(subtask.id, today: context.today, now: context.now)
        }
    }

    private func abandonSubtask(_ context: inout SimulationContext) throws {
        if let subtask = chooseCurrentPendingSubtask(context.engine, today: context.today, rng: &context.rng) {
            try context.engine.abandonSubtask(subtask.id, today: context.today, now: context.now)
        }
    }

    private func setManualProgress(_ context: inout SimulationContext) throws {
        if let trace = chooseCurrentPendingTraceWithoutSubtasks(context.engine, today: context.today, rng: &context.rng) {
            try context.engine.setManualProgress(
                traceID: trace.id,
                percent: context.rng.nextInt(121) - 10,
                today: context.today,
                now: context.now
            )
        }
    }

    private func markCompleted(_ context: inout SimulationContext) throws {
        if let trace = chooseCurrentPendingTrace(context.engine, today: context.today, rng: &context.rng) {
            try context.engine.markCompleted(traceID: trace.id, today: context.today, now: context.now)
        }
    }

    private func returnToPool(_ context: inout SimulationContext) throws {
        if let trace = choosePendingTrace(context.engine, rng: &context.rng) {
            try context.engine.returnToPool(traceID: trace.id, today: context.today, now: context.now)
        }
    }

    private func rescheduleFuturePlan(_ context: inout SimulationContext) throws {
        if let trace = chooseFuturePendingTrace(context.engine, today: context.today, rng: &context.rng) {
            try context.engine.rescheduleFuturePlan(
                traceID: trace.id,
                targetDate: offset(context.today, by: 1 + context.rng.nextInt(5)),
                today: context.today,
                now: context.now
            )
        }
    }

    private func advanceDay(_ context: inout SimulationContext) throws {
        context.today = offset(context.today, by: 1)
        try context.engine.settleDays(upTo: context.today, now: context.now)
    }

    private func continueTrace(_ context: inout SimulationContext) throws {
        if let item = context.engine.unfinishedPool().first, let trace = item.unfinishedTraces.last {
            _ = try context.engine.continueTrace(
                traceID: trace.id,
                targetDate: offset(context.today, by: context.rng.nextInt(2)),
                today: context.today,
                now: context.now
            )
        }
    }

    private func changeTrace(_ context: inout SimulationContext) throws {
        if let trace = chooseCurrentPendingTrace(context.engine, today: context.today, rng: &context.rng) {
            _ = try context.engine.changeTrace(
                traceID: trace.id,
                newTitle: "changed-\(context.iteration)-\(context.step)",
                today: context.today,
                now: context.now
            )
        }
    }

    private func assertInvariants(_ engine: NoonmarkEngine, today: LocalDate) throws {
        for trace in engine.traces.values {
            XCTAssertNotNil(engine.chains[trace.chainID], "trace chain must exist")
            let definition = try XCTUnwrap(engine.definitions[trace.definitionID], "trace definition must exist")
            XCTAssertEqual(definition.chainID, trace.chainID, "trace definition must belong to trace chain")
            XCTAssertNotNil(engine.days[trace.date], "scheduled trace day must exist")

            let progress = engine.traceProgress(for: trace.id)
            XCTAssertGreaterThanOrEqual(progress.percent, 0)
            XCTAssertLessThanOrEqual(progress.percent, 100)
            XCTAssertLessThanOrEqual(progress.floorPercent, progress.percent)
        }

        let pendingByActiveChain = Dictionary(grouping: engine.traces.values.filter { trace in
            trace.status == .pending && engine.chains[trace.chainID]?.state == .active
        }, by: \.chainID)
        for (chainID, pending) in pendingByActiveChain {
            XCTAssertLessThanOrEqual(pending.count, 1, "chain \(chainID) has more than one active trace")
        }

        for subtask in engine.subtasks.values {
            let trace = try XCTUnwrap(engine.traces[subtask.traceID], "subtask parent trace must exist")
            XCTAssertNotNil(engine.chains[trace.chainID], "subtask parent chain must exist")
        }

        for date in Set(engine.traces.values.map(\.date)) {
            let summary = engine.calendarSummary(for: date)
            let traces = engine.traces.values.filter {
                $0.date == date && $0.formsDayHistory
            }
            XCTAssertEqual(summary.total, traces.count)
            XCTAssertEqual(summary.completed, traces.filter { $0.status == .completed }.count)
            XCTAssertEqual(summary.pending, traces.filter { $0.status == .pending }.count)
            XCTAssertEqual(summary.unfinished, traces.filter { $0.status == .unfinished }.count)
            XCTAssertEqual(summary.heatLevel, min(summary.completed, 4))
        }

        for trace in engine.traces.values where trace.date < today {
            XCTAssertNotEqual(trace.status, .pending, "settled history cannot keep pending traces")
        }
    }

    private func choosePendingTrace(_ engine: NoonmarkEngine, rng: inout SeededGenerator) -> DayTrace? {
        chooseTrace(engine.traces.values.filter { $0.status == .pending }, engine: engine, rng: &rng)
    }

    private func chooseCurrentPendingTrace(_ engine: NoonmarkEngine, today: LocalDate, rng: inout SeededGenerator) -> DayTrace? {
        chooseTrace(engine.traces.values.filter { $0.status == .pending && $0.date == today }, engine: engine, rng: &rng)
    }

    private func chooseFuturePendingTrace(_ engine: NoonmarkEngine, today: LocalDate, rng: inout SeededGenerator) -> DayTrace? {
        chooseTrace(engine.traces.values.filter { $0.status == .pending && $0.date > today }, engine: engine, rng: &rng)
    }

    private func chooseCurrentPendingTraceWithoutSubtasks(_ engine: NoonmarkEngine, today: LocalDate, rng: inout SeededGenerator) -> DayTrace? {
        chooseTrace(engine.traces.values.filter { trace in
            trace.status == .pending
                && trace.date == today
                && engine.subtasks.values.contains { $0.traceID == trace.id } == false
        }, engine: engine, rng: &rng)
    }

    private func chooseCurrentPendingSubtask(_ engine: NoonmarkEngine, today: LocalDate, rng: inout SeededGenerator) -> Subtask? {
        chooseSubtask(engine.subtasks.values.filter { subtask in
            guard let trace = engine.traces[subtask.traceID] else { return false }
            return subtask.status == .pending && trace.status == .pending && trace.date == today
        }, engine: engine, rng: &rng)
    }

    private func choose<T>(_ values: [T], rng: inout SeededGenerator) -> T? {
        guard values.isEmpty == false else { return nil }
        return values[rng.nextInt(values.count)]
    }

    private func chooseTrace(_ values: [DayTrace], engine: NoonmarkEngine, rng: inout SeededGenerator) -> DayTrace? {
        choose(values.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let lhsTitle = engine.definitions[lhs.definitionID]?.title ?? ""
            let rhsTitle = engine.definitions[rhs.definitionID]?.title ?? ""
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
            if lhs.continuationSeq != rhs.continuationSeq { return lhs.continuationSeq < rhs.continuationSeq }
            return lhs.createdAt < rhs.createdAt
        }, rng: &rng)
    }

    private func chooseSubtask(_ values: [Subtask], engine: NoonmarkEngine, rng: inout SeededGenerator) -> Subtask? {
        choose(values.sorted { lhs, rhs in
            let lhsTrace = engine.traces[lhs.traceID]
            let rhsTrace = engine.traces[rhs.traceID]
            if lhsTrace?.date != rhsTrace?.date { return (lhsTrace?.date ?? LocalDate("0001-01-01")) < (rhsTrace?.date ?? LocalDate("0001-01-01")) }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.createdAt < rhs.createdAt
        }, rng: &rng)
    }

    private func offset(_ date: LocalDate, by days: Int) -> LocalDate {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day + days
        let calendar = Calendar(identifier: .gregorian)
        let shifted = calendar.date(from: components) ?? Date()
        let out = calendar.dateComponents([.year, .month, .day], from: shifted)
        return LocalDate(year: out.year ?? date.year, month: out.month ?? date.month, day: out.day ?? date.day)
    }

    private func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xA11C_E123 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}
