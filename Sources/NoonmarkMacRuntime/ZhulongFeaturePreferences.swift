import Foundation

public enum ZhulongPermissionPolicy:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case allow
    case ask
    case deny
}

public enum ZhulongConversationPermissionDecision: Equatable, Sendable {
    case allow
    case ask
    case deny
}

public struct ZhulongConversationPermissionCeiling: Codable, Equatable, Sendable {
    public static let defaultValue = ZhulongConversationPermissionCeiling(
        dataReading: .allow,
        remoteSending: .allow
    )

    public var dataReading: ZhulongPermissionPolicy
    public var remoteSending: ZhulongPermissionPolicy

    public init(
        dataReading: ZhulongPermissionPolicy,
        remoteSending: ZhulongPermissionPolicy
    ) {
        self.dataReading = dataReading
        self.remoteSending = remoteSending
    }

    public func decision(
        sendsRemotely: Bool
    ) -> ZhulongConversationPermissionDecision {
        let policies = sendsRemotely
            ? [dataReading, remoteSending]
            : [dataReading]
        if policies.contains(.deny) {
            return .deny
        }
        if policies.contains(.ask) {
            return .ask
        }
        return .allow
    }
}

public struct ZhulongFeaturePreferences: Codable, Equatable, Sendable {
    public static let defaultValue = ZhulongFeaturePreferences(
        pageEnabled: true,
        automaticClassificationEnabled: true,
        conversationPermissionCeiling: .defaultValue
    )

    static let failClosedValue = ZhulongFeaturePreferences(
        pageEnabled: true,
        automaticClassificationEnabled: false,
        conversationPermissionCeiling: .init(
            dataReading: .deny,
            remoteSending: .deny
        )
    )

    public var pageEnabled: Bool
    public var automaticClassificationEnabled: Bool
    public var conversationPermissionCeiling:
        ZhulongConversationPermissionCeiling

    public init(
        pageEnabled: Bool,
        automaticClassificationEnabled: Bool,
        conversationPermissionCeiling:
        ZhulongConversationPermissionCeiling = .defaultValue
    ) {
        self.pageEnabled = pageEnabled
        self.automaticClassificationEnabled = automaticClassificationEnabled
        self.conversationPermissionCeiling =
            conversationPermissionCeiling
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
        guard defaults.object(forKey: storageKey) != nil else {
            return .defaultValue
        }
        guard let data = defaults.data(forKey: storageKey) else {
            return .failClosedValue
        }
        guard let preferences = try? decoder.decode(
            ZhulongFeaturePreferences.self,
            from: data
        ) else {
            return .failClosedValue
        }
        return preferences
    }

    public func save(_ preferences: ZhulongFeaturePreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
