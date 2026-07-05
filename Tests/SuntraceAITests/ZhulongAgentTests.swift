import XCTest
@testable import SuntraceAI
@testable import SuntraceCore

final class ZhulongAgentTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let day2 = LocalDate("2026-07-06")
    private let day3 = LocalDate("2026-07-07")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAgentReturnsDraftWithoutMutatingCoreState() async throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "整理烛龙框架", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "写接口边界", now: now)

        let provider = MockAIProvider(
            response: AIProviderResponse(
                text: "事实：当前任务已有一个子任务。建议：补充验收子任务。",
                proposedOperations: [.addSubtask(traceID: traceID, title: "补充验收")],
                confidence: 0.72
            )
        )
        let agent = ZhulongAgent(providerRegistry: AIProviderRegistry(providers: [provider]))
        let scope = AIScopeSnapshot.day(date: day1, from: engine, requestedAt: now)

        let draft = try await agent.generateDraft(task: .taskDecomposition, scope: scope, now: now)

        XCTAssertEqual(draft.kind, .taskDecomposition)
        XCTAssertEqual(draft.proposedOperations, [.addSubtask(traceID: traceID, title: "补充验收")])
        XCTAssertEqual(draft.confidence, 0.72)
        XCTAssertEqual(engine.subtasks.values.filter { $0.traceID == traceID }.count, 1)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
    }

    func testLocalInsightAnalyzerReportsContinuationAndPartialProgress() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "跨日推进大任务", now: now)
        let day1TraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)

        let day2TraceID = try engine.continueTrace(traceID: day1TraceID, targetDate: day2, today: day2, now: now)
        engine.settleDays(upTo: day3, now: now)

        let day3TraceID = try engine.continueTrace(traceID: day2TraceID, targetDate: day3, today: day3, now: now)
        let completedSubtaskID = try engine.addSubtask(traceID: day3TraceID, title: "完成接口设计", now: now)
        _ = try engine.addSubtask(traceID: day3TraceID, title: "补齐 provider 测试", now: now)
        try engine.completeSubtask(completedSubtaskID, today: day3, now: now)

        let dayScope = AIScopeSnapshot.day(date: day3, from: engine, requestedAt: now)
        let poolScope = AIScopeSnapshot.pools(from: engine, includeTaskPool: false, includeUnfinishedPool: true, includeCompletedPool: false, requestedAt: now)
        let scope = AIScopeSnapshot.combined([dayScope, poolScope], requestedAt: now)
        let report = LocalInsightAnalyzer().analyze(scope)

        XCTAssertTrue(report.evidence.contains { $0.metric == "max_continuation_seq" && $0.value == 2 })
        XCTAssertTrue(report.evidence.contains { $0.metric == "partial_progress_traces" && $0.value == 1 })
        XCTAssertTrue(report.evidence.contains { $0.metric == "unfinished_chain_count" && $0.value == 1 })
    }

    func testPromptBuilderOmitsInternalIDsAndKeepsGuardrails() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "调研 agent 框架", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let scope = AIScopeSnapshot.day(date: day1, from: engine, requestedAt: now)
        let report = LocalInsightAnalyzer().analyze(scope)

        let request = AIPromptBuilder().buildRequest(task: .habitInsight, scope: scope, report: report)

        XCTAssertTrue(request.systemPrompt.contains("AI 建议草稿"))
        XCTAssertTrue(request.systemPrompt.contains("不能直接改写历史事实"))
        XCTAssertTrue(request.userPrompt.contains("调研 agent 框架"))
        XCTAssertFalse(request.userPrompt.contains(traceID.description))
        XCTAssertFalse(request.userPrompt.contains(chainID.description))
    }

    func testRegistryRejectsDisabledProvider() async throws {
        let providerID = AIProviderID("disabled-provider")
        let provider = MockAIProvider(
            providerID: providerID,
            enabled: false,
            response: AIProviderResponse(text: "disabled")
        )
        let agent = ZhulongAgent(providerRegistry: AIProviderRegistry(providers: [provider]))
        let engine = SuntraceEngine()
        _ = try engine.createPoolTask(title: "配置 provider", now: now)
        let scope = AIScopeSnapshot.pools(from: engine, includeTaskPool: true, includeUnfinishedPool: false, includeCompletedPool: false, requestedAt: now)

        do {
            _ = try await agent.generateDraft(task: .dailyReview, scope: scope, providerID: providerID, now: now)
            XCTFail("disabled provider should be rejected")
        } catch let error as ZhulongAIError {
            XCTAssertEqual(error, .providerDisabled(providerID))
        }
    }

    func testDelegationPolicyAllowsOnlyPermittedOperationsBeforeExpiration() throws {
        let traceID = DayTraceID()
        let policy = AIDelegationPolicy.delegatedHousekeeper(
            allowedOperations: [.addSubtask],
            maxOperationsPerRun: 3,
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertTrue(
            policy.allowsAutomaticExecution(of: .addSubtask(traceID: traceID, title: "补充验收"), at: now)
        )
        XCTAssertFalse(
            policy.allowsAutomaticExecution(of: .updateDailyReview(date: day1, summary: "复盘", unfinishedReason: nil, tomorrowNote: nil), at: now)
        )
        XCTAssertFalse(
            policy.allowsAutomaticExecution(of: .addSubtask(traceID: traceID, title: "补充验收"), at: now.addingTimeInterval(61))
        )
    }

    func testConfirmEachOperationPolicyNeverAutoExecutes() throws {
        let policy = AIDelegationPolicy.confirmEachOperation

        XCTAssertFalse(
            policy.allowsAutomaticExecution(of: .createPoolTask(title: "整理任务池", notes: nil), at: now)
        )
    }
}
