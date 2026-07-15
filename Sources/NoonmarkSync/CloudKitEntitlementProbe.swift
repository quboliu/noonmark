import Foundation
import Security

public enum CloudKitEntitlementProbe {
    public static let containerIdentifiersKey =
        "com.apple.developer.icloud-container-identifiers"
    public static let servicesKey = "com.apple.developer.icloud-services"
    public static let environmentKey =
        "com.apple.developer.icloud-container-environment"
    public static let remoteNotificationsKey =
        "com.apple.developer.aps-environment"

    @discardableResult
    public static func validate(
        containerIdentifier: String,
        containerIdentifiers: [String]?,
        services: [String]?,
        environment: String?,
        remoteNotificationsEnvironment: String?
    ) throws -> CloudKitSyncEnvironment {
        guard containerIdentifiers?.contains(containerIdentifier) == true else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                containerIdentifiersKey
            )
        }
        guard services?.contains("CloudKit") == true else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                servicesKey
            )
        }
        guard let environment = environment.flatMap(
            CloudKitSyncEnvironment.init(rawValue:)
        ) else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                environmentKey
            )
        }
        let expectedRemoteEnvironment = switch environment {
        case .development: "development"
        case .production: "production"
        }
        guard remoteNotificationsEnvironment == expectedRemoteEnvironment
        else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                remoteNotificationsKey
            )
        }
        return environment
    }

    @discardableResult
    public static func validateCurrentProcess(
        containerIdentifier: String
    ) throws -> CloudKitSyncEnvironment {
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                containerIdentifiersKey
            )
        }
        let containerIdentifiers = entitlement(
            containerIdentifiersKey,
            from: task
        ) as? [String]
        let services = entitlement(servicesKey, from: task) as? [String]
        let environment = entitlement(environmentKey, from: task) as? String
        let remoteEnvironment = entitlement(
            remoteNotificationsKey,
            from: task
        ) as? String
        return try validate(
            containerIdentifier: containerIdentifier,
            containerIdentifiers: containerIdentifiers,
            services: services,
            environment: environment,
            remoteNotificationsEnvironment: remoteEnvironment
        )
    }

    private static func entitlement(
        _ key: String,
        from task: SecTask
    ) -> Any? {
        return SecTaskCopyValueForEntitlement(
            task,
            key as CFString,
            nil
        )
    }
}
