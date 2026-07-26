import NoonmarkCore
@testable import NoonmarkDemoSupport
import Testing

@Suite("交互式演示基线")
struct NoonmarkDemoFixtureTests {
    private let anchorDate = LocalDate("2026-07-24")

    @Test("固定十天用户故事覆盖所有主要任务投影")
    func coversTenDayUserStory() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )

        #expect(fixture.storyDates.count == 10)
        #expect(fixture.storyDates.first == LocalDate("2026-07-15"))
        #expect(fixture.storyDates.last == anchorDate)
        #expect(fixture.engine.getDayTodo(date: anchorDate).traces.isEmpty == false)
        #expect(fixture.engine.taskPool().isEmpty == false)
        #expect(fixture.engine.futurePlans(today: anchorDate).isEmpty == false)
        #expect(fixture.engine.unfinishedPool().isEmpty == false)
        #expect(fixture.engine.completedPool().isEmpty == false)
        let track = try #require(
            fixture.engine.taskCycleTracks(today: anchorDate).first
        )
        #expect(track.days.count == 13)
        #expect(track.appears(in: .future))
        #expect(track.appears(in: .unfinished))
        #expect(track.appears(in: .completed))
        #expect(fixture.report.isComplete)
    }

    @Test("基线包含真实边界状态而非仅有页面占位数据")
    func coversBoundaryStates() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let engine = fixture.engine
        let todayTraces = engine.getDayTodo(date: anchorDate).traces

        #expect(todayTraces.filter { $0.pinOrder != nil }.count >= 2)
        #expect(
            todayTraces.contains {
                $0.status == .deferred
                    && engine.canWithdrawDeferral(
                        sourceTraceID: $0.id,
                        today: anchorDate
                    )
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .returnedToPool
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .changed
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .abandoned
            }
        )
        #expect(
            Set(engine.snapshot().subtasks.map(\.status))
                .isSuperset(of: [.pending, .completed, .unfinished, .abandoned])
        )
        #expect(
            engine.taskPool().contains {
                $0.definition.plannedSubtasks.count >= 3
                    && $0.chain.activeNoteEntries.isEmpty == false
            }
        )
        #expect(
            engine.snapshot().days.filter {
                $0.reviewSummary?.isEmpty == false
            }.count >= 6
        )
    }

    @Test("相同锚点生成相同语义覆盖清单")
    func producesDeterministicSemanticReport() throws {
        let first = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let second = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )

        #expect(first.report == second.report)
    }
}
