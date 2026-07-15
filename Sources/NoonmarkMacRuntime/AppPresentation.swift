import NoonmarkCore

public enum AppPresentationErrorContext: Sendable {
    case classificationCatalog
    case classificationMutation
}

public enum AppPresentationError: Error, Equatable, Sendable {
    case classificationCatalogUnavailable
    case invalidClassificationName
    case classificationHistoryLocked
    case classificationTaskUnavailable
    case classificationResourceUnavailable
    case classificationActionUnavailable
    case unexpected
}

public enum GroupManagementMetric: Sendable {
    case category
    case label
}

public struct GroupManagementCopy: Equatable, Sendable {
    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    public var title: String {
        language == .chinese ? "分组与标签" : "Groups & Tags"
    }

    public var subtitle: String {
        language == .chinese
            ? "用一个分组建立结构，再用标签补充横向线索。"
            : "Use one group for structure, then add tags for cross-cutting context."
    }

    public var categoryTitle: String {
        language == .chinese ? "分组" : "Groups"
    }

    public var labelTitle: String {
        language == .chinese ? "标签" : "Tags"
    }

    public var manageAction: String {
        language == .chinese ? "管理分组与标签" : "Manage groups & tags"
    }

    public var manageShortAction: String {
        language == .chinese ? "管理" : "Manage"
    }

    public func metricTitle(_ metric: GroupManagementMetric) -> String {
        switch metric {
        case .category:
            categoryTitle
        case .label:
            labelTitle
        }
    }

    public func metricAccessibilityLabel(
        _ metric: GroupManagementMetric,
        count: Int
    ) -> String {
        switch (language, metric) {
        case (.chinese, .category):
            "\(count) 个分组"
        case (.chinese, .label):
            "\(count) 个标签"
        case (.english, .category):
            count == 1 ? "1 group" : "\(count) groups"
        case (.english, .label):
            count == 1 ? "1 tag" : "\(count) tags"
        }
    }
}

public struct AppPresentation: Sendable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    public var groupManagement: GroupManagementCopy {
        GroupManagementCopy(language: language)
    }

    public func message(for error: AppPresentationError) -> String {
        switch error {
        case .classificationCatalogUnavailable:
            localized(
                chinese: "暂时无法读取分组与标签，请稍后再试。",
                english: "Groups and tags are temporarily unavailable. Try again shortly."
            )
        case .invalidClassificationName:
            localized(
                chinese: "名称无效，请输入不为空且未重复的名称。",
                english: "Enter a non-empty, unique name."
            )
        case .classificationHistoryLocked:
            localized(
                chinese: "历史分组与标签不可直接改写。",
                english: "Historical groups and tags cannot be changed directly."
            )
        case .classificationTaskUnavailable:
            localized(
                chinese: "当前任务不能修改分组与标签。",
                english: "Groups and tags cannot be changed for this task."
            )
        case .classificationResourceUnavailable:
            localized(
                chinese: "相关分组或标签已不存在，请刷新后再试。",
                english: "The related group or tag no longer exists. Refresh and try again."
            )
        case .classificationActionUnavailable:
            localized(
                chinese: "当前状态不允许这项分组与标签操作。",
                english: "This group or tag action is unavailable in the current state."
            )
        case .unexpected:
            localized(
                chinese: "操作未完成，请稍后再试。",
                english: "The action could not be completed. Try again shortly."
            )
        }
    }

    private func localized(chinese: String, english: String) -> String {
        language == .chinese ? chinese : english
    }

    public static func classify(
        _ error: Error,
        for context: AppPresentationErrorContext
    ) -> AppPresentationError {
        switch context {
        case .classificationCatalog:
            return .classificationCatalogUnavailable
        case .classificationMutation:
            guard let error = error as? NoonmarkError else {
                return .unexpected
            }
            switch error {
            case let .invalidInput(reason)
                where isClassificationNameValidationFailure(reason):
                return .invalidClassificationName
            case .invalidTitle:
                return .invalidClassificationName
            case .immutableHistory, .lockedDay, .historicalCompletionCannotBeUndone:
                return .classificationHistoryLocked
            case .chainAbandoned:
                return .classificationTaskUnavailable
            case .notFound, .noActiveTrace:
                return .classificationResourceUnavailable
            case .activeTraceAlreadyExists,
                 .invalidInput,
                 .invalidTransition,
                 .futurePlanCannotComplete,
                 .openSubtasksPreventCompletion:
                return .classificationActionUnavailable
            }
        }
    }

    private static func isClassificationNameValidationFailure(_ reason: String) -> Bool {
        switch reason {
        case "classification name cannot be empty",
             "classification name has no searchable Unicode content",
             "task category name already exists",
             "task label name already exists":
            true
        default:
            false
        }
    }
}
