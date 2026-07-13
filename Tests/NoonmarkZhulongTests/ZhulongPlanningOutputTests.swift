@testable import NoonmarkZhulong
import XCTest

final class ZhulongPlanningOutputTests: XCTestCase {
    func testPlanArtifactRequiresAcyclicStagesWithResolvableDependencies() throws {
        let first = try makeStage(id: "measure", dependencies: ["delivery"])
        let second = try makeStage(id: "delivery", dependencies: ["measure"])

        XCTAssertThrowsError(
            try ZhulongPlanArtifactProposal(
                summary: "先测量，再交付。",
                stages: [first, second],
                decisionExplanations: [makeExplanation()],
                precisionClaims: []
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidStageGraph)
        }

        let missing = try makeStage(id: "delivery", dependencies: ["unknown"])
        XCTAssertThrowsError(
            try ZhulongPlanArtifactProposal(
                summary: "依赖不存在。",
                stages: [missing],
                decisionExplanations: [makeExplanation()],
                precisionClaims: []
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidStageGraph)
        }
    }

    func testRollingPlanRequiresNearTermDeliverablesAndLaterTriggerConditions() throws {
        XCTAssertThrowsError(
            try ZhulongPlanStageDraft(
                id: "near",
                title: "近期阶段",
                objective: "形成可验证切片",
                horizon: .nearTerm,
                dependencyIDs: [],
                deliverables: [],
                triggerCondition: nil
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidStageDetail)
        }

        XCTAssertThrowsError(
            try ZhulongPlanStageDraft(
                id: "later",
                title: "远期阶段",
                objective: "根据新证据继续",
                horizon: .later,
                dependencyIDs: ["near"],
                deliverables: [],
                triggerCondition: nil
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidStageDetail)
        }
    }

    func testNearTermStageCannotDependOnTriggerOnlyLaterStage() throws {
        let later = try ZhulongPlanStageDraft(
            id: "later",
            title: "远期阶段",
            objective: "等待证据",
            horizon: .later,
            dependencyIDs: [],
            deliverables: [],
            triggerCondition: "证据已取得"
        )
        let near = try makeStage(id: "near", dependencies: ["later"])

        XCTAssertThrowsError(
            try ZhulongPlanArtifactProposal(
                summary: "近期不能被远期触发条件阻塞。",
                stages: [later, near],
                decisionExplanations: [makeExplanation()],
                precisionClaims: []
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidStageGraph)
        }
    }

    func testParserRejectsPrecisionOutsideTypedEvidenceBoundClaims() throws {
        for precision in [
            "2026-08-01 完成", "2026年8月1日完成", "需要 8 story points",
            "成功率 75%", "成功概率0.75", "成功率 0.75", "success rate 0.75",
            "2026/08/01 完成", "August 1, 2026 完成", "eleven story points",
            "twenty percent probability", "success probability seventy-five percent",
            "成功率百分之七十五", "八个故事点"
        ] {
            let output = completePlanningJSON().replacingOccurrences(
                of: "取得真实工作量数据",
                with: precision
            )
            XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(output)) { error in
                XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
            }
        }

        let evidence = completePlanningJSON().replacingOccurrences(
            of: "当前没有同度量工程数据",
            with: "历史成功率 99%"
        )
        XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(evidence)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
        }

        XCTAssertThrowsError(
            try ZhulongDecisionGateDraft(
                summary: "证据不足。",
                prompt: "怎样继续？",
                reason: "缺少测量。",
                evidenceGaps: ["没有同度量历史"],
                options: [
                    try ZhulongDecisionGateOptionDraft(
                        id: "estimate",
                        title: "直接估算",
                        impact: "承诺 8 story points"
                    ),
                    try ZhulongDecisionGateOptionDraft(
                        id: "stop",
                        title: "停止",
                        impact: "不再规划"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
        }
    }

    func testParserAcceptsTypedPrecisionWithExplicitBasisAndRejectsInvalidClaim() throws {
        let claim = """
        "precisionClaims":[{
          "kind":"targetDate",
          "dateValue":"2026-08-01",
          "numericValue":null,
          "basisSource":"hardConstraint",
          "basis":"用户要求 2026-08-01 前完成",
          "basisValue":"2026-08-01",
          "dataScope":null
        }]
        """
        let valid = completePlanningJSON()
            .replacingOccurrences(of: "不得伪造日期", with: "用户要求 2026-08-01 前完成")
            .replacingOccurrences(of: "\"precisionClaims\": []", with: claim)
        guard case let .planArtifact(artifact) = try ZhulongPlanningOutputParser().parse(valid) else {
            return XCTFail("Expected a plan artifact")
        }
        XCTAssertEqual(artifact.precisionClaims.first?.dateValue, "2026-08-01")

        let invalid = valid.replacingOccurrences(of: "2026-08-01 前完成", with: "尽快完成")
        XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(invalid)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidPrecisionClaim)
        }
    }

    func testNumericPrecisionRequiresExactTokenInBasis() throws {
        XCTAssertNoThrow(
            try ZhulongPlanningPrecisionClaimDraft(
                kind: .effortPoints,
                dateValue: nil,
                numericValue: 8,
                basisSource: .hardConstraint,
                basis: "上限是 8 story points",
                basisValue: "8",
                dataScope: nil
            )
        )
        for claim in [
            (ZhulongPlanningPrecisionKind.effortPoints, 8.0, "上限是 18 points"),
            (.probability, 0.7, "历史概率 0.75"),
            (.effortPoints, 8, "使用模型版本 8"),
            (.probability, 0.75, "采用配置版本 0.75"),
            (.probability, 0.75, "0.75 probabilityVersion"),
            (.probability, 0.75, "0.75 成功率版本")
        ] {
            XCTAssertThrowsError(
                try ZhulongPlanningPrecisionClaimDraft(
                    kind: claim.0,
                    dateValue: nil,
                    numericValue: claim.1,
                    basisSource: .hardConstraint,
                    basis: claim.2,
                    basisValue: claim.1 == 8 ? "8" : String(claim.1),
                    dataScope: nil
                )
            ) { error in
                XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidPrecisionClaim)
            }
        }
    }

    func testPrecisionBasisNormalizesEquivalentDateAndProbabilityRepresentations() throws {
        XCTAssertNoThrow(
            try ZhulongPlanningPrecisionClaimDraft(
                kind: .targetDate,
                dateValue: "2026-08-01",
                numericValue: nil,
                basisSource: .hardConstraint,
                basis: "必须在 2026年8月1日 前完成",
                basisValue: "2026年8月1日",
                dataScope: nil
            )
        )
        XCTAssertNoThrow(
            try ZhulongPlanningPrecisionClaimDraft(
                kind: .targetDate,
                dateValue: "2026-08-01",
                numericValue: nil,
                basisSource: .userDecision,
                basis: "Deadline is August 1, 2026",
                basisValue: "August 1, 2026",
                dataScope: nil
            )
        )
        XCTAssertNoThrow(
            try ZhulongPlanningPrecisionClaimDraft(
                kind: .probability,
                dateValue: nil,
                numericValue: 0.75,
                basisSource: .localEvidence,
                basis: "历史完成率 75%",
                basisValue: "75%",
                dataScope: .currentDayTodo
            )
        )
        for basis in [
            "成功率为 0.75", "置信度约为 0.75", "probability: 0.75",
            "completion rate = 0.75"
        ] {
            XCTAssertNoThrow(
                try ZhulongPlanningPrecisionClaimDraft(
                    kind: .probability,
                    dateValue: nil,
                    numericValue: 0.75,
                    basisSource: .hardConstraint,
                    basis: basis,
                    basisValue: "0.75",
                    dataScope: nil
                )
            )
        }
        for basis in ["8 effort points", "workload: 8 points"] {
            XCTAssertNoThrow(
                try ZhulongPlanningPrecisionClaimDraft(
                    kind: .effortPoints,
                    dateValue: nil,
                    numericValue: 8,
                    basisSource: .userDecision,
                    basis: basis,
                    basisValue: "8",
                    dataScope: nil
                )
            )
        }
        for basis in ["当前进度 75%", "资源利用率 75%", "折扣 75%"] {
            XCTAssertThrowsError(
                try ZhulongPlanningPrecisionClaimDraft(
                    kind: .probability,
                    dateValue: nil,
                    numericValue: 0.75,
                    basisSource: .localEvidence,
                    basis: basis,
                    basisValue: "75%",
                    dataScope: .currentDayTodo
                )
            ) { error in
                XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidPrecisionClaim)
            }
        }
    }

    func testEveryPrecisionExpressionInOneProvenanceSentenceRequiresItsOwnClaim() throws {
        let dateAndProbability = "必须在 2026-08-01 前完成，成功率 75%"
        let dateClaim = """
        "precisionClaims":[{
          "kind":"targetDate","dateValue":"2026-08-01","numericValue":null,
          "basisSource":"hardConstraint","basis":"\(dateAndProbability)",
          "basisValue":"2026-08-01","dataScope":null
        }]
        """
        let dateOnly = completePlanningJSON()
            .replacingOccurrences(of: "不得伪造日期", with: dateAndProbability)
            .replacingOccurrences(of: "\"precisionClaims\": []", with: dateClaim)
        XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(dateOnly)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
        }

        let effortAndProbability = "工作量 8 points，成功率 75%"
        let effortClaim = """
        "precisionClaims":[{
          "kind":"effortPoints","dateValue":null,"numericValue":8,
          "basisSource":"hardConstraint","basis":"\(effortAndProbability)",
          "basisValue":"8","dataScope":null
        }]
        """
        let effortOnly = completePlanningJSON()
            .replacingOccurrences(of: "不得伪造日期", with: effortAndProbability)
            .replacingOccurrences(of: "\"precisionClaims\": []", with: effortClaim)
        XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(effortOnly)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
        }

        let completeClaims = dateClaim.replacingOccurrences(
            of: "]",
            with: """
            ,{
              "kind":"probability","dateValue":null,"numericValue":0.75,
              "basisSource":"hardConstraint","basis":"\(dateAndProbability)",
              "basisValue":"75%","dataScope":null
            }]
            """
        )
        let fullyTyped = completePlanningJSON()
            .replacingOccurrences(of: "不得伪造日期", with: dateAndProbability)
            .replacingOccurrences(of: "\"precisionClaims\": []", with: completeClaims)
        XCTAssertNoThrow(try ZhulongPlanningOutputParser().parse(fullyTyped))

        let overlappingClaims = completeClaims.replacingOccurrences(
            of: "}]",
            with: """
            },{
              "kind":"effortPoints","dateValue":null,"numericValue":2026,
              "basisSource":"hardConstraint","basis":"\(dateAndProbability)",
              "basisValue":"2026","dataScope":null
            }]
            """
        )
        let overlapping = completePlanningJSON()
            .replacingOccurrences(of: "不得伪造日期", with: dateAndProbability)
            .replacingOccurrences(of: "\"precisionClaims\": []", with: overlappingClaims)
        XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(overlapping)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidPrecisionClaim)
        }
    }

    func testRepeatedValueClaimsCannotBorrowOneSemanticOccurrence() throws {
        for scenario in [
            (
                "成功率 0.75，配置版本 0.75",
                "probability", "null", "0.75", "0.75"
            ),
            (
                "工作量 8 points，模型版本 8",
                "effortPoints", "null", "8", "8"
            )
        ] {
            let claims = """
            "precisionClaims":[
              {"kind":"\(scenario.1)","dateValue":\(scenario.2),"numericValue":\(scenario.3),"basisSource":"hardConstraint","basis":"\(scenario.0)","basisValue":"\(scenario.4)","dataScope":null},
              {"kind":"\(scenario.1)","dateValue":\(scenario.2),"numericValue":\(scenario.3),"basisSource":"hardConstraint","basis":"\(scenario.0)","basisValue":"\(scenario.4)","dataScope":null}
            ]
            """
            let output = completePlanningJSON()
                .replacingOccurrences(of: "不得伪造日期", with: scenario.0)
                .replacingOccurrences(of: "\"precisionClaims\": []", with: claims)
            XCTAssertThrowsError(try ZhulongPlanningOutputParser().parse(output)) { error in
                XCTAssertEqual(error as? ZhulongPlanningOutputError, .unboundPrecision)
            }
        }
    }

    func testDecisionExplanationRequiresEveryWhiteBoxDisclosureLayer() throws {
        XCTAssertThrowsError(
            try ZhulongDecisionExplanationDraft(
                subject: "为何先测量",
                userDecisions: ["先完成 Mac 版"],
                assumptions: [],
                dataScopes: [.currentDayTodo],
                evidence: ["当前没有同度量工程数据"],
                constraints: ["不得伪造日期"],
                alternatives: [
                    try ZhulongDecisionAlternativeDraft(
                        title: "直接排期",
                        tradeoffs: ["更快，但没有证据"]
                    )
                ],
                counterexamples: ["直接排期会隐藏证据缺口"],
                rationale: "测量后才能形成可信承诺。",
                uncertainties: [],
                expectedImpacts: ["推迟具体排期"],
                requiredAuthorizations: [.todoWrite]
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .incompleteDecisionExplanation)
        }
    }

    func testDecisionGateRequiresDistinctOptionsAndExplicitEvidenceGap() throws {
        let option = try ZhulongDecisionGateOptionDraft(
            id: "investigate",
            title: "先调查",
            impact: "先形成测量任务，不生成日期"
        )
        XCTAssertThrowsError(
            try ZhulongDecisionGateDraft(
                summary: "证据不足。",
                prompt: "这次规划应该怎样继续？",
                reason: "缺少真实工作量测量。",
                evidenceGaps: [],
                options: [option, option]
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidDecisionGate)
        }
    }

    func testParserDecodesDecisionGateAndRejectsUnknownFields() throws {
        let parser = ZhulongPlanningOutputParser()
        let output = try parser.parse("""
        {
          "kind": "decisionGate",
          "summary": "证据不足。",
          "prompt": "这次规划应该怎样继续？",
          "reason": "缺少真实工作量测量。",
          "evidenceGaps": ["没有同度量实现历史"],
          "options": [
            {"id":"investigate","title":"先调查","impact":"先形成测量任务"},
            {"id":"stop","title":"保留未决","impact":"停止本轮规划"}
          ]
        }
        """)

        guard case let .decisionGate(gate) = output else {
            return XCTFail("Expected a decision gate")
        }
        XCTAssertEqual(gate.options.map(\.id), ["investigate", "stop"])

        XCTAssertThrowsError(try parser.parse("""
        {
          "kind": "decisionGate",
          "summary": "证据不足。",
          "prompt": "怎样继续？",
          "reason": "缺少测量。",
          "evidenceGaps": ["没有测量"],
          "options": [
            {"id":"a","title":"A","impact":"影响 A"},
            {"id":"b","title":"B","impact":"影响 B"}
          ],
          "hiddenAuthority": true
        }
        """)) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .unknownField)
        }
    }

    func testParserDecodesCompleteRollingPlanArtifact() throws {
        let output = try ZhulongPlanningOutputParser().parse(completePlanningJSON())

        guard case let .planArtifact(draft) = output else {
            return XCTFail("Expected a plan artifact")
        }
        XCTAssertEqual(draft.stages.map(\.id), ["measure", "delivery"])
        XCTAssertEqual(draft.stages.last?.triggerCondition, "测量记录已审查")
    }

    private func completePlanningJSON() -> String {
        """
        {
          "kind": "planArtifact",
          "summary": "先取得测量，再交付近期切片。",
          "stages": [
            {
              "id": "measure",
              "title": "工程测量",
              "objective": "取得真实工作量数据",
              "horizon": "nearTerm",
              "dependencyIDs": [],
              "deliverables": ["测量记录"],
              "triggerCondition": null
            },
            {
              "id": "delivery",
              "title": "交付切片",
              "objective": "完成任务成形闭环",
              "horizon": "later",
              "dependencyIDs": ["measure"],
              "deliverables": [],
              "triggerCondition": "测量记录已审查"
            }
          ],
          "decisionExplanations": [
            {
              "subject": "为何先测量",
              "userDecisions": ["先完成 Mac 版"],
              "assumptions": [],
              "dataScopes": ["currentDayTodo"],
              "evidence": ["当前没有同度量工程数据"],
              "constraints": ["不得伪造日期"],
              "alternatives": [
                {"title":"直接排期","tradeoffs":["快，但没有证据"]},
                {"title":"先测量","tradeoffs":["较慢，但可校准"]}
              ],
              "counterexamples": ["直接排期会隐藏证据缺口"],
              "rationale": "测量后才能形成可信承诺。",
              "uncertainties": ["测量结果尚未知"],
              "expectedImpacts": ["近期只生成调查任务"],
              "requiredAuthorizations": ["todoWrite"]
            }
          ],
          "precisionClaims": []
        }
        """
    }

    private func makeStage(id: String, dependencies: [String]) throws -> ZhulongPlanStageDraft {
        try ZhulongPlanStageDraft(
            id: id,
            title: "阶段 \(id)",
            objective: "完成 \(id)",
            horizon: .nearTerm,
            dependencyIDs: dependencies,
            deliverables: ["产物 \(id)"],
            triggerCondition: nil
        )
    }

    private func makeExplanation() throws -> ZhulongDecisionExplanationDraft {
        try ZhulongDecisionExplanationDraft(
            subject: "为何先测量",
            userDecisions: ["先完成 Mac 版"],
            assumptions: [],
            dataScopes: [.currentDayTodo],
            evidence: ["当前没有同度量工程数据"],
            constraints: ["不得伪造日期"],
            alternatives: [
                try ZhulongDecisionAlternativeDraft(title: "直接排期", tradeoffs: ["快，但没有证据"]),
                try ZhulongDecisionAlternativeDraft(title: "先测量", tradeoffs: ["较慢，但可校准"])
            ],
            counterexamples: ["直接排期会隐藏证据缺口"],
            rationale: "测量后才能形成可信承诺。",
            uncertainties: ["测量结果尚未知"],
            expectedImpacts: ["近期只生成调查任务"],
            requiredAuthorizations: [.todoWrite]
        )
    }
}
