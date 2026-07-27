import Foundation

public enum RecurringFuturePlanVisibility: Int, CaseIterable, Codable,
    Equatable, Hashable, Sendable
{
    case sevenDays = 7
    case fifteenDays = 15
    case thirtyDays = 30

    public static let defaultValue = RecurringFuturePlanVisibility.fifteenDays

    public var dayCount: Int {
        rawValue
    }
}

@MainActor
public final class RecurringFuturePlanVisibilityRepository {
    public static let defaultStorageKey =
        "Noonmark.RecurringFuturePlanVisibility.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> RecurringFuturePlanVisibility {
        guard let value = RecurringFuturePlanVisibility(
            rawValue: defaults.integer(forKey: storageKey)
        ) else {
            return .defaultValue
        }
        return value
    }

    public func save(_ visibility: RecurringFuturePlanVisibility) {
        defaults.set(visibility.rawValue, forKey: storageKey)
    }
}
