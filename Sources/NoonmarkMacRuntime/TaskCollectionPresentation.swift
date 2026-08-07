import Foundation

public enum TaskCollectionPage: String, CaseIterable, Codable, Equatable, Sendable {
    case dayTodo
    case taskPool
    case unfinished
    case completed
}

public enum TaskCollectionOrganization: String, CaseIterable, Codable, Equatable, Sendable {
    case flat
    case grouped
}

public enum TaskCollectionSortKey: String, CaseIterable, Codable, Equatable, Sendable {
    case time
    case title
}

public enum TaskCollectionSortDirection: String, CaseIterable, Codable, Equatable, Sendable {
    case ascending
    case descending
}

public struct TaskCollectionPresentationPreference: Codable, Equatable, Sendable {
    public var organization: TaskCollectionOrganization
    public var sortKey: TaskCollectionSortKey
    public var direction: TaskCollectionSortDirection

    public init(
        organization: TaskCollectionOrganization,
        sortKey: TaskCollectionSortKey,
        direction: TaskCollectionSortDirection
    ) {
        self.organization = organization
        self.sortKey = sortKey
        self.direction = direction
    }

    public static func defaultValue(for page: TaskCollectionPage) -> Self {
        switch page {
        case .dayTodo:
            Self(organization: .flat, sortKey: .time, direction: .ascending)
        case .taskPool:
            Self(organization: .grouped, sortKey: .time, direction: .ascending)
        case .unfinished, .completed:
            Self(organization: .flat, sortKey: .time, direction: .descending)
        }
    }

    public var showsCategoryInItemRows: Bool {
        organization == .flat
    }

    public func showsCategoryInItemRows(
        in section: TaskCollectionPresentationSection
    ) -> Bool {
        showsCategoryInItemRows || section.title == nil
    }
}

public enum TaskCollectionCategoryApproval: String, Codable, Equatable, Sendable {
    case userApproved
    case pendingAIReview
}

public struct TaskCategoryVisualStyle: Equatable, Sendable {
    public let foregroundColorHex: String?
    public let usesTintedBackground: Bool

    public init(
        colorHex: String?,
        isUserApproved: Bool
    ) {
        foregroundColorHex = colorHex
        usesTintedBackground = isUserApproved
    }
}

/// A presentation-only category seam. It lets collection pages consume the
/// category identity and approval fact without owning classification policy.
public struct TaskCollectionCategoryPresentation: Equatable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String?
    public let approval: TaskCollectionCategoryApproval

    public init(
        id: String,
        name: String,
        colorHex: String?,
        approval: TaskCollectionCategoryApproval
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.approval = approval
    }

    public var visualStyle: TaskCategoryVisualStyle {
        TaskCategoryVisualStyle(
            colorHex: colorHex,
            isUserApproved: approval == .userApproved
        )
    }
}

public struct TaskCollectionPresentationItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let time: Date
    public let category: TaskCollectionCategoryPresentation?
    public let precedence: Int
    public let fixedOrder: Int?

    public init(
        id: String,
        title: String,
        time: Date,
        category: TaskCollectionCategoryPresentation?,
        precedence: Int = 0,
        fixedOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.time = time
        self.category = category
        self.precedence = precedence
        self.fixedOrder = fixedOrder
    }
}

public struct TaskCollectionPresentationSection: Equatable, Sendable {
    /// 置顶队列 section 的固定 id：投影器把 pinned 项单独抽成这个无标题 section，
    /// 呈现层据它渲染图钉分组头。
    public static let pinnedQueueSectionID = "fixed"

    public let id: String
    public let title: String?
    public let category: TaskCollectionCategoryPresentation?
    public let items: [TaskCollectionPresentationItem]
    public let precedence: Int

    public var isPinnedQueue: Bool {
        id == Self.pinnedQueueSectionID
    }
}

public struct TaskCollectionPresentationProjector: Sendable {
    public init() {}

    public func sections(
        for items: [TaskCollectionPresentationItem],
        preference: TaskCollectionPresentationPreference,
        ungroupedTitle: String
    ) -> [TaskCollectionPresentationSection] {
        let fixedItems = items.filter { $0.fixedOrder != nil }.sorted {
            if $0.fixedOrder != $1.fixedOrder {
                return ($0.fixedOrder ?? .max) < ($1.fixedOrder ?? .max)
            }
            return $0.id < $1.id
        }
        let flexibleItems = items.filter { $0.fixedOrder == nil }

        guard preference.organization == .grouped else {
            var sections: [TaskCollectionPresentationSection] = []
            if fixedItems.isEmpty == false {
                sections.append(
                    TaskCollectionPresentationSection(
                        id: TaskCollectionPresentationSection.pinnedQueueSectionID,
                        title: nil,
                        category: nil,
                        items: fixedItems,
                        precedence: .min
                    )
                )
            }
            if flexibleItems.isEmpty == false || sections.isEmpty {
                sections.append(
                    TaskCollectionPresentationSection(
                        id: "flat",
                        title: nil,
                        category: nil,
                        items: sorted(flexibleItems, by: preference),
                        precedence: 0
                    )
                )
            }
            return sections
        }

        var sections: [TaskCollectionPresentationSection] = []
        if fixedItems.isEmpty == false {
            sections.append(
                TaskCollectionPresentationSection(
                    id: TaskCollectionPresentationSection.pinnedQueueSectionID,
                    title: nil,
                    category: nil,
                    items: fixedItems,
                    precedence: .min
                )
            )
        }

        let grouped = Dictionary(grouping: flexibleItems) {
            SectionKey(
                categoryID: $0.category?.id
            )
        }
        sections.append(contentsOf: grouped.map { key, groupItems in
            let category = groupItems.compactMap(\.category).first
            return TaskCollectionPresentationSection(
                id: key.categoryID ?? "ungrouped",
                title: category?.name ?? ungroupedTitle,
                category: category,
                items: sorted(groupItems, by: preference),
                precedence: 0
            )
        }.sorted(by: sectionPrecedes))
        return sections
    }

    private func sorted(
        _ items: [TaskCollectionPresentationItem],
        by preference: TaskCollectionPresentationPreference
    ) -> [TaskCollectionPresentationItem] {
        items.sorted { lhs, rhs in
            if lhs.precedence != rhs.precedence {
                return lhs.precedence < rhs.precedence
            }
            let comparison: ComparisonResult = switch preference.sortKey {
            case .time:
                if lhs.time == rhs.time {
                    .orderedSame
                } else {
                    lhs.time < rhs.time ? .orderedAscending : .orderedDescending
                }
            case .title:
                lhs.title.localizedStandardCompare(rhs.title)
            }

            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }
            switch preference.direction {
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
    }

    private func sectionPrecedes(
        _ lhs: TaskCollectionPresentationSection,
        _ rhs: TaskCollectionPresentationSection
    ) -> Bool {
        if lhs.precedence != rhs.precedence {
            return lhs.precedence < rhs.precedence
        }
        if lhs.category == nil {
            return false
        }
        if rhs.category == nil {
            return true
        }
        let comparison = (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "")
        if comparison == .orderedSame {
            return lhs.id < rhs.id
        }
        return comparison == .orderedAscending
    }

    private struct SectionKey: Hashable {
        let categoryID: String?
    }
}

@MainActor
public final class TaskCollectionPresentationPreferenceRepository {
    public nonisolated static let defaultStorageKeyPrefix = "Noonmark.TaskCollectionPresentation.v1"

    private let defaults: UserDefaults
    private let storageKeyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKeyPrefix: String = defaultStorageKeyPrefix
    ) {
        self.defaults = defaults
        self.storageKeyPrefix = storageKeyPrefix
    }

    public func storageKey(for page: TaskCollectionPage) -> String {
        "\(storageKeyPrefix).\(page.rawValue)"
    }

    public func load(for page: TaskCollectionPage) -> TaskCollectionPresentationPreference {
        guard let data = defaults.data(forKey: storageKey(for: page)),
              let decoded = try? decoder.decode(TaskCollectionPresentationPreference.self, from: data)
        else {
            return .defaultValue(for: page)
        }
        return decoded
    }

    public func save(
        _ preference: TaskCollectionPresentationPreference,
        for page: TaskCollectionPage
    ) {
        guard let data = try? encoder.encode(preference) else { return }
        defaults.set(data, forKey: storageKey(for: page))
    }
}
