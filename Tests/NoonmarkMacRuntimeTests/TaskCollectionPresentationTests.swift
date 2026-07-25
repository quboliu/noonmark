import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class TaskCollectionPresentationTests: XCTestCase {
    func testGroupedOrganizationHidesRowCategoryAndFlatOrganizationShowsIt() {
        let grouped = TaskCollectionPresentationPreference(
            organization: .grouped,
            sortKey: .time,
            direction: .ascending
        )
        let flat = TaskCollectionPresentationPreference(
            organization: .flat,
            sortKey: .time,
            direction: .ascending
        )

        XCTAssertFalse(grouped.showsCategoryInItemRows)
        XCTAssertTrue(flat.showsCategoryInItemRows)
    }

    func testPinnedQueueKeepsRowCategoryWhenGroupedSectionsHideIt() throws {
        let category = TaskCollectionCategoryPresentation(
            id: "category-work",
            name: "Work",
            colorHex: "#2A6FDB",
            approval: .userApproved
        )
        let preference = TaskCollectionPresentationPreference(
            organization: .grouped,
            sortKey: .time,
            direction: .ascending
        )
        let sections = TaskCollectionPresentationProjector().sections(
            for: [
                TaskCollectionPresentationItem(
                    id: "pinned",
                    title: "Pinned",
                    time: Date(timeIntervalSince1970: 1000),
                    category: category,
                    fixedOrder: 0
                ),
                TaskCollectionPresentationItem(
                    id: "normal",
                    title: "Normal",
                    time: Date(timeIntervalSince1970: 1001),
                    category: category
                ),
            ],
            preference: preference,
            ungroupedTitle: "Ungrouped"
        )

        let pinnedSection = try XCTUnwrap(sections.first)
        let groupedSection = try XCTUnwrap(sections.last)
        XCTAssertNil(pinnedSection.title)
        XCTAssertEqual(groupedSection.title, "Work")
        XCTAssertEqual(pinnedSection.items.first?.category, category)
        XCTAssertTrue(preference.showsCategoryInItemRows(in: pinnedSection))
        XCTAssertFalse(preference.showsCategoryInItemRows(in: groupedSection))
    }

    func testDefaultsPreserveEachPageCurrentPresentation() {
        XCTAssertEqual(
            TaskCollectionPresentationPreference.defaultValue(for: .dayTodo),
            TaskCollectionPresentationPreference(
                organization: .flat,
                sortKey: .time,
                direction: .ascending
            )
        )
        XCTAssertEqual(
            TaskCollectionPresentationPreference.defaultValue(for: .taskPool),
            TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .ascending
            )
        )
        XCTAssertEqual(
            TaskCollectionPresentationPreference.defaultValue(for: .unfinished),
            TaskCollectionPresentationPreference(
                organization: .flat,
                sortKey: .time,
                direction: .descending
            )
        )
        XCTAssertEqual(
            TaskCollectionPresentationPreference.defaultValue(for: .completed),
            TaskCollectionPresentationPreference(
                organization: .flat,
                sortKey: .time,
                direction: .descending
            )
        )
    }

    func testCategoryVisualStyleKeepsItsForegroundColorBeforeUserApproval() {
        let approved = TaskCategoryVisualStyle(
            colorHex: "#D1477A",
            isUserApproved: true
        )
        let pendingReview = TaskCategoryVisualStyle(
            colorHex: "#2A6FDB",
            isUserApproved: false
        )

        XCTAssertEqual(approved.foregroundColorHex, "#D1477A")
        XCTAssertEqual(pendingReview.foregroundColorHex, "#2A6FDB")
        XCTAssertTrue(approved.usesTintedBackground)
        XCTAssertFalse(pendingReview.usesTintedBackground)
    }

    func testRepositoryPersistsEachPageIndependentlyAndFailsClosed() {
        let suiteName = "TaskCollectionPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = TaskCollectionPresentationPreferenceRepository(defaults: defaults)
        let pool = TaskCollectionPresentationPreference(
            organization: .flat,
            sortKey: .title,
            direction: .descending
        )
        let completed = TaskCollectionPresentationPreference(
            organization: .grouped,
            sortKey: .title,
            direction: .ascending
        )

        repository.save(pool, for: .taskPool)
        repository.save(completed, for: .completed)

        XCTAssertEqual(repository.load(for: .taskPool), pool)
        XCTAssertEqual(repository.load(for: .unfinished), .defaultValue(for: .unfinished))
        XCTAssertEqual(repository.load(for: .completed), completed)

        defaults.set(Data("not-json".utf8), forKey: repository.storageKey(for: .completed))
        XCTAssertEqual(repository.load(for: .completed), .defaultValue(for: .completed))
    }

    func testAllEightCombinationsHaveDeterministicOrdering() {
        let firstCategory = TaskCollectionCategoryPresentation(
            id: "category-b",
            name: "Beta",
            colorHex: "#112233",
            approval: .userApproved
        )
        let secondCategory = TaskCollectionCategoryPresentation(
            id: "category-a",
            name: "Alpha",
            colorHex: nil,
            approval: .pendingAIReview
        )
        let base = Date(timeIntervalSince1970: 1000)
        let items = [
            TaskCollectionPresentationItem(id: "4", title: "Zulu", time: base, category: firstCategory),
            TaskCollectionPresentationItem(id: "3", title: "Alpha", time: base.addingTimeInterval(20), category: firstCategory),
            TaskCollectionPresentationItem(id: "2", title: "Bravo", time: base.addingTimeInterval(10), category: secondCategory),
            TaskCollectionPresentationItem(id: "1", title: "Alpha", time: base.addingTimeInterval(10), category: nil),
        ]
        let projector = TaskCollectionPresentationProjector()

        for organization in TaskCollectionOrganization.allCases {
            for sortKey in TaskCollectionSortKey.allCases {
                for direction in TaskCollectionSortDirection.allCases {
                    let preference = TaskCollectionPresentationPreference(
                        organization: organization,
                        sortKey: sortKey,
                        direction: direction
                    )
                    let result = projector.sections(
                        for: items,
                        preference: preference,
                        ungroupedTitle: "Ungrouped"
                    )

                    XCTAssertEqual(result.flatMap(\.items).count, items.count)
                    if organization == .grouped {
                        XCTAssertEqual(result.map(\.title), ["Alpha", "Beta", "Ungrouped"])
                    } else {
                        XCTAssertEqual(result.count, 1)
                        XCTAssertNil(result[0].category)
                    }

                    let expectedIDs = expectedOrder(
                        items,
                        sortKey: sortKey,
                        direction: direction,
                        grouped: organization == .grouped
                    )
                    XCTAssertEqual(result.flatMap(\.items).map(\.id), expectedIDs)
                }
            }
        }
    }

    func testFixedQueueAndPrecedenceOverrideGroupingAndViewSort() {
        let firstCategory = TaskCollectionCategoryPresentation(
            id: "category-b",
            name: "Beta",
            colorHex: nil,
            approval: .userApproved
        )
        let secondCategory = TaskCollectionCategoryPresentation(
            id: "category-a",
            name: "Alpha",
            colorHex: nil,
            approval: .userApproved
        )
        let base = Date(timeIntervalSince1970: 1000)
        let items = [
            TaskCollectionPresentationItem(
                id: "settled-a",
                title: "A settled",
                time: base,
                category: secondCategory,
                precedence: 1
            ),
            TaskCollectionPresentationItem(
                id: "normal-b",
                title: "B normal",
                time: base.addingTimeInterval(20),
                category: firstCategory
            ),
            TaskCollectionPresentationItem(
                id: "pinned-second",
                title: "Z pinned",
                time: base,
                category: firstCategory,
                fixedOrder: 2
            ),
            TaskCollectionPresentationItem(
                id: "pinned-first",
                title: "A pinned",
                time: base.addingTimeInterval(30),
                category: secondCategory,
                fixedOrder: 1
            ),
            TaskCollectionPresentationItem(
                id: "normal-a",
                title: "A normal",
                time: base.addingTimeInterval(10),
                category: secondCategory
            ),
        ]

        let sections = TaskCollectionPresentationProjector().sections(
            for: items,
            preference: TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .title,
                direction: .descending
            ),
            ungroupedTitle: "Ungrouped"
        )

        XCTAssertEqual(
            sections.flatMap(\.items).map(\.id),
            [
                "pinned-first",
                "pinned-second",
                "normal-a",
                "settled-a",
                "normal-b",
            ]
        )
        XCTAssertNil(sections.first?.title)
    }

    func testGroupingKeepsPendingAndSettledItemsInOneCategorySection() {
        let base = Date(timeIntervalSince1970: 1000)
        let sections = TaskCollectionPresentationProjector().sections(
            for: [
                TaskCollectionPresentationItem(
                    id: "settled",
                    title: "Settled",
                    time: base,
                    category: nil,
                    precedence: 1
                ),
                TaskCollectionPresentationItem(
                    id: "pending",
                    title: "Pending",
                    time: base.addingTimeInterval(1),
                    category: nil
                ),
            ],
            preference: TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .descending
            ),
            ungroupedTitle: "Ungrouped"
        )

        XCTAssertEqual(
            sections.map(\.title),
            ["Ungrouped"]
        )
        XCTAssertEqual(
            sections.flatMap(\.items).map(\.id),
            ["pending", "settled"]
        )
    }

    private func expectedOrder(
        _ items: [TaskCollectionPresentationItem],
        sortKey: TaskCollectionSortKey,
        direction: TaskCollectionSortDirection,
        grouped: Bool
    ) -> [String] {
        func sorted(_ input: [TaskCollectionPresentationItem]) -> [String] {
            input.sorted { lhs, rhs in
                let comparison: ComparisonResult = switch sortKey {
                case .time:
                    lhs.time == rhs.time
                        ? .orderedSame
                        : (lhs.time < rhs.time ? .orderedAscending : .orderedDescending)
                case .title:
                    lhs.title.localizedStandardCompare(rhs.title)
                }
                if comparison == .orderedSame { return lhs.id < rhs.id }
                return direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }.map(\.id)
        }

        guard grouped else { return sorted(items) }
        return [
            sorted(items.filter { $0.category?.id == "category-a" }),
            sorted(items.filter { $0.category?.id == "category-b" }),
            sorted(items.filter { $0.category == nil }),
        ].flatMap { $0 }
    }
}
