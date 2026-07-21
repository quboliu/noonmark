import Foundation

public struct ZhulongFeaturePreferences: Codable, Equatable, Sendable {
    public static let defaultValue = ZhulongFeaturePreferences(
        pageEnabled: true,
        automaticClassificationEnabled: true
    )

    public var pageEnabled: Bool
    public var automaticClassificationEnabled: Bool

    public init(
        pageEnabled: Bool,
        automaticClassificationEnabled: Bool
    ) {
        self.pageEnabled = pageEnabled
        self.automaticClassificationEnabled = automaticClassificationEnabled
    }
}

public struct ZhulongFeatureAvailability: Equatable, Sendable {
    public let providerEnabled: Bool
    public let preferences: ZhulongFeaturePreferences

    public init(
        providerEnabled: Bool,
        preferences: ZhulongFeaturePreferences
    ) {
        self.providerEnabled = providerEnabled
        self.preferences = preferences
    }

    public var pageIsAvailable: Bool {
        preferences.pageEnabled
    }

    public var shouldEnqueueAutomaticClassification: Bool {
        preferences.automaticClassificationEnabled
    }

    public var workerMayRun: Bool {
        preferences.automaticClassificationEnabled
    }

    public var providerCanExecute: Bool {
        providerEnabled
    }
}

@MainActor
public final class ZhulongFeaturePreferencesRepository {
    public static let defaultStorageKey = "Noonmark.ZhulongFeaturePreferences.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = ZhulongFeaturePreferencesRepository.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> ZhulongFeaturePreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? decoder.decode(
                  ZhulongFeaturePreferences.self,
                  from: data
              )
        else {
            return .defaultValue
        }
        return preferences
    }

    public func save(_ preferences: ZhulongFeaturePreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
