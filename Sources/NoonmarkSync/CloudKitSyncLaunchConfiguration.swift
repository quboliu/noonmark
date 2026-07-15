import Foundation

public enum CloudKitSyncLaunchConfigurationError: Error, Equatable, Sendable {
    case invalidArguments
}

extension CloudKitSyncLaunchConfigurationError: LocalizedError {
    public var errorDescription: String? {
        "CloudKit launch arguments are missing, malformed, or ambiguous."
    }
}

public struct CloudKitSyncLaunchConfiguration: Equatable, Sendable {
    public static let containerArgument = "--cloudkit-container-id"
    public static let zoneArgument = "--cloudkit-zone-name"

    public let containerIdentifier: String
    public let zoneName: String

    public static func resolve(
        arguments: [String]
    ) throws -> CloudKitSyncLaunchConfiguration? {
        let containerValues = try values(
            after: containerArgument,
            in: arguments
        )
        let zoneValues = try values(after: zoneArgument, in: arguments)
        guard containerValues.count <= 1, zoneValues.count <= 1 else {
            throw CloudKitSyncLaunchConfigurationError.invalidArguments
        }
        guard let rawContainerIdentifier = containerValues.first else {
            guard zoneValues.isEmpty else {
                throw CloudKitSyncLaunchConfigurationError.invalidArguments
            }
            return nil
        }

        let containerIdentifier = rawContainerIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let zoneName = (zoneValues.first
            ?? CloudKitSyncEngineTransport.defaultZoneName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitZoneIsIsolated = zoneValues.isEmpty
            || (zoneName.hasPrefix(
                CloudKitSyncEngineTransport.liveValidationZonePrefix
            )
                && zoneName.count > CloudKitSyncEngineTransport
                .liveValidationZonePrefix.count)
        guard containerIdentifier.hasPrefix("iCloud."),
              containerIdentifier.count > "iCloud.".count,
              zoneName.isEmpty == false,
              explicitZoneIsIsolated
        else {
            throw CloudKitSyncLaunchConfigurationError.invalidArguments
        }

        return CloudKitSyncLaunchConfiguration(
            containerIdentifier: containerIdentifier,
            zoneName: zoneName
        )
    }

    private static func values(
        after flag: String,
        in arguments: [String]
    ) throws -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == flag {
            let valueIndex = arguments.index(after: index)
            guard arguments.indices.contains(valueIndex),
                  arguments[valueIndex].hasPrefix("--") == false,
                  arguments[valueIndex].isEmpty == false
            else {
                throw CloudKitSyncLaunchConfigurationError.invalidArguments
            }
            values.append(arguments[valueIndex])
        }
        return values
    }
}
