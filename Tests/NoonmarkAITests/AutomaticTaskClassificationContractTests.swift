@testable import NoonmarkAI
import XCTest

final class AutomaticTaskClassificationContractTests: XCTestCase {
    func testBuilderSendsOnlyTaskAndActiveCatalogAsJSONObjectData() throws {
        let input = AutomaticTaskClassificationInput(
            title: "修复日历边框",
            description: "补齐月视图首行与首列。",
            catalog: AutomaticTaskClassificationCatalog(
                revision: "catalog-r7",
                categories: [
                    AutomaticTaskClassificationCatalogItem(handle: "category-0", displayName: "工程")
                ],
                labels: [
                    AutomaticTaskClassificationCatalogItem(handle: "label-0", displayName: "SwiftUI")
                ]
            )
        )

        let request = try AutomaticTaskClassificationPromptBuilder().makeRequest(for: input)

        XCTAssertEqual(request.responseSchemaName, "noonmark.automatic-task-classification.v1")
        XCTAssertEqual(request.responseFormat, .jsonObject)
        XCTAssertTrue(request.systemPrompt.contains("只输出一个 JSON object"))
        XCTAssertTrue(request.systemPrompt.contains("恰好 1 个 category"))
        XCTAssertTrue(request.systemPrompt.contains("1 至 3 个 labels"))

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.userPrompt.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(payload.keys), ["task", "catalog"])

        let task = try XCTUnwrap(payload["task"] as? [String: String])
        XCTAssertEqual(task, [
            "title": "修复日历边框",
            "description": "补齐月视图首行与首列。"
        ])

        let catalog = try XCTUnwrap(payload["catalog"] as? [String: Any])
        XCTAssertEqual(Set(catalog.keys), ["revision", "categories", "labels"])
        XCTAssertEqual(catalog["revision"] as? String, "catalog-r7")
        XCTAssertEqual(
            catalog["categories"] as? [[String: String]],
            [["handle": "category-0", "displayName": "工程"]]
        )
        XCTAssertEqual(
            catalog["labels"] as? [[String: String]],
            [["handle": "label-0", "displayName": "SwiftUI"]]
        )
        XCTAssertFalse(request.userPrompt.contains("UUID"))
        XCTAssertFalse(request.userPrompt.contains("history"))
        XCTAssertFalse(request.userPrompt.contains("notes"))
    }

    func testDecoderReturnsTypedReuseAndNormalizedCreateChoices() throws {
        let input = makeInput()
        let response = AIProviderResponse(
            text: """
            {"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0"},{"action":"create","name":"  UI Bug  "}]}
            """
        )

        let proposal = try AutomaticTaskClassificationDecoder().decode(response, against: input)

        XCTAssertEqual(proposal.category, .reuse(handle: "category-0"))
        XCTAssertEqual(proposal.labels, [
            .reuse(handle: "label-0"),
            .create(name: "UI Bug")
        ])
    }

    func testDecoderAcceptsNewCategoryAndLabelWhenCatalogIsEmpty() throws {
        let input = AutomaticTaskClassificationInput(
            title: "买牛奶",
            description: nil,
            catalog: AutomaticTaskClassificationCatalog(
                revision: "catalog-empty",
                categories: [],
                labels: []
            )
        )
        let response = AIProviderResponse(
            text: #"{"category":{"action":"create","name":"生活"},"labels":[{"action":"create","name":"采购"}]}"#
        )

        let proposal = try AutomaticTaskClassificationDecoder().decode(response, against: input)

        XCTAssertEqual(proposal.category, .create(name: "生活"))
        XCTAssertEqual(proposal.labels, [.create(name: "采购")])
    }

    func testDecoderRejectsUnknownOrMissingFields() {
        let invalidResponses = [
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0"}],"reason":"looks right"}"#,
            #"{"category":{"action":"reuse","handle":"category-0"}}"#,
            #"{"category":{"action":"create"},"labels":[{"action":"reuse","handle":"label-0"}]}"#,
            #"{"category":{"action":"reuse","handle":"category-0","name":"工程"},"labels":[{"action":"reuse","handle":"label-0"}]}"#,
            #"{"category":{"action":"replace","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0"}]}"#
        ]

        for text in invalidResponses {
            XCTAssertThrowsError(
                try AutomaticTaskClassificationDecoder().decode(
                    AIProviderResponse(text: text),
                    against: makeInput()
                ),
                "must reject \(text)"
            )
        }
    }

    func testDecoderRejectsDuplicateKeysBeforeFoundationCanCollapseThem() {
        let duplicateResponses = [
            #"{"category":{"action":"reuse","handle":"category-0"},"category":{"action":"create","name":"覆盖"},"labels":[{"action":"reuse","handle":"label-0"}]}"#,
            #"{"category":{"action":"reuse","action":"create","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0"}]}"#,
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0","\u0068andle":"label-0"}]}"#
        ]

        for text in duplicateResponses {
            XCTAssertThrowsError(
                try AutomaticTaskClassificationDecoder().decode(
                    AIProviderResponse(text: text),
                    against: makeInput()
                ),
                "must reject duplicate JSON key in \(text)"
            ) { error in
                XCTAssertEqual(
                    error as? AutomaticTaskClassificationContractError,
                    .malformedResponse
                )
            }
        }
    }

    func testDecoderRejectsResponseBeyondDurableProposalLimit() {
        let oversized = String(repeating: " ", count: 262_145)

        XCTAssertThrowsError(
            try AutomaticTaskClassificationDecoder().decode(
                AIProviderResponse(text: oversized),
                against: makeInput()
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomaticTaskClassificationContractError,
                .malformedResponse
            )
        }
    }

    func testDecoderRejectsInvalidLabelCounts() {
        let invalidResponses = [
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[]}"#,
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"create","name":"一"},{"action":"create","name":"二"},{"action":"create","name":"三"},{"action":"create","name":"四"}]}"#
        ]

        for text in invalidResponses {
            XCTAssertThrowsError(
                try AutomaticTaskClassificationDecoder().decode(
                    AIProviderResponse(text: text),
                    against: makeInput()
                ),
                "must reject \(text)"
            )
        }
    }

    func testDecoderRejectsHandlesOutsideTheirActiveCatalogType() {
        XCTAssertThrowsError(
            try AutomaticTaskClassificationDecoder().decode(
                AIProviderResponse(
                    text: #"{"category":{"action":"reuse","handle":"label-0"},"labels":[{"action":"reuse","handle":"label-0"}]}"#
                ),
                against: makeInput()
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomaticTaskClassificationContractError,
                .unknownCategoryHandle("label-0")
            )
        }

        XCTAssertThrowsError(
            try AutomaticTaskClassificationDecoder().decode(
                AIProviderResponse(
                    text: #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"reuse","handle":"missing-label"}]}"#
                ),
                against: makeInput()
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomaticTaskClassificationContractError,
                .unknownLabelHandle("missing-label")
            )
        }
    }

    func testDecoderRejectsDuplicateLabelSelectionsAndCatalogNameRecreation() {
        let duplicateResponses = [
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"create","name":"UI Bug"},{"action":"create","name":" ui   bug "}]}"#,
            #"{"category":{"action":"reuse","handle":"category-0"},"labels":[{"action":"reuse","handle":"label-0"},{"action":"create","name":"swiftui"}]}"#
        ]

        for text in duplicateResponses {
            XCTAssertThrowsError(
                try AutomaticTaskClassificationDecoder().decode(
                    AIProviderResponse(text: text),
                    against: makeInput()
                ),
                "must reject \(text)"
            )
        }
    }

    func testBuilderRejectsAmbiguousCatalogHandles() {
        let input = AutomaticTaskClassificationInput(
            title: "任务",
            description: nil,
            catalog: AutomaticTaskClassificationCatalog(
                revision: "catalog-r7",
                categories: [
                    AutomaticTaskClassificationCatalogItem(handle: "shared", displayName: "工程")
                ],
                labels: [
                    AutomaticTaskClassificationCatalogItem(handle: "shared", displayName: "SwiftUI")
                ]
            )
        )

        XCTAssertThrowsError(try AutomaticTaskClassificationPromptBuilder().makeRequest(for: input)) { error in
            XCTAssertEqual(
                error as? AutomaticTaskClassificationContractError,
                .duplicateCatalogHandle("shared")
            )
        }
    }

    func testTypedProposalCannotBeConstructedWithInvalidLabelCount() {
        XCTAssertThrowsError(
            try AutomaticTaskClassificationProposal(
                category: .create(name: "工程"),
                labels: []
            )
        )
        XCTAssertThrowsError(
            try AutomaticTaskClassificationProposal(
                category: .create(name: "工程"),
                labels: [
                    .create(name: "一"),
                    .create(name: "二"),
                    .create(name: "三"),
                    .create(name: "四")
                ]
            )
        )
    }

    private func makeInput() -> AutomaticTaskClassificationInput {
        AutomaticTaskClassificationInput(
            title: "修复日历边框",
            description: nil,
            catalog: AutomaticTaskClassificationCatalog(
                revision: "catalog-r7",
                categories: [
                    AutomaticTaskClassificationCatalogItem(handle: "category-0", displayName: "工程")
                ],
                labels: [
                    AutomaticTaskClassificationCatalogItem(handle: "label-0", displayName: "SwiftUI")
                ]
            )
        )
    }
}
