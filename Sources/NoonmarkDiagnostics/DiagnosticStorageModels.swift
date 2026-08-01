import Darwin
import Foundation

public enum DiagnosticSchemaVersion {
    public static let evidence = RecordedEvidence.currentSchemaVersion
    public static let metricRedaction = 1
}

public enum DiagnosticBinarySHA256Scope: String, Codable, Sendable {
    case linkedBeforeBundleSigning = "linked-before-bundle-signing"
    case finalSignedExecutable = "final-signed-executable"
}

public struct DiagnosticAppIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let commitSHA: String?
    public let buildDate: String?
    public let runtime: String?
    public let minimumOSVersion: String?
    public let buildArchitecture: String
    public let operatingSystemMajorVersion: Int
    public let operatingSystemMinorVersion: Int
    public let operatingSystemPatchVersion: Int
    public let darwinVersion: String?
    public let architecture: String
    public let binaryUUID: String?
    public let binarySHA256: String?
    public let binarySHA256Scope: DiagnosticBinarySHA256Scope?

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case commitSHA
        case buildDate
        case runtime
        case minimumOSVersion
        case buildArchitecture
        case operatingSystemMajorVersion
        case operatingSystemMinorVersion
        case operatingSystemPatchVersion
        case darwinVersion
        case architecture
        case binaryUUID
        case binarySHA256
        case binarySHA256Scope
    }

    init(
        version: String,
        build: String,
        commitSHA: String? = nil,
        buildDate: String? = nil,
        runtime: String? = nil,
        minimumOSVersion: String? = nil,
        buildArchitecture: String? = nil,
        operatingSystemMajorVersion: Int,
        operatingSystemMinorVersion: Int,
        operatingSystemPatchVersion: Int = 0,
        darwinVersion: String? = nil,
        architecture: String,
        binaryUUID: String? = nil,
        binarySHA256: String? = nil,
        binarySHA256Scope: DiagnosticBinarySHA256Scope? = nil
    ) {
        self.version = Self.safeBuildValue(version)
        self.build = Self.safeBuildValue(build)
        self.commitSHA = commitSHA.flatMap(Self.safeCommitSHA)
        self.buildDate = buildDate.flatMap(Self.safeBuildDate)
        self.runtime = runtime.flatMap(Self.safeRuntime)
        self.minimumOSVersion = minimumOSVersion.flatMap(
            Self.safeDottedVersion
        )
        self.buildArchitecture = Self.safeBuildValue(
            buildArchitecture ?? architecture
        )
        self.operatingSystemMajorVersion = max(0, operatingSystemMajorVersion)
        self.operatingSystemMinorVersion = max(0, operatingSystemMinorVersion)
        self.operatingSystemPatchVersion = max(0, operatingSystemPatchVersion)
        self.darwinVersion = darwinVersion.flatMap(Self.safeDarwinVersion)
        self.architecture = Self.safeBuildValue(architecture)
        self.binaryUUID = binaryUUID.flatMap(Self.safeBinaryUUIDSet)
        self.binarySHA256 = binarySHA256.flatMap(Self.safeBinarySHA256)
        self.binarySHA256Scope = binarySHA256Scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let architecture = try container.decode(
            String.self,
            forKey: .architecture
        )
        self.init(
            version: try container.decode(String.self, forKey: .version),
            build: try container.decode(String.self, forKey: .build),
            commitSHA: try container.decodeIfPresent(
                String.self,
                forKey: .commitSHA
            ),
            buildDate: try container.decodeIfPresent(
                String.self,
                forKey: .buildDate
            ),
            runtime: try container.decodeIfPresent(
                String.self,
                forKey: .runtime
            ),
            minimumOSVersion: try container.decodeIfPresent(
                String.self,
                forKey: .minimumOSVersion
            ),
            buildArchitecture: try container.decodeIfPresent(
                String.self,
                forKey: .buildArchitecture
            ) ?? architecture,
            operatingSystemMajorVersion: try container.decode(
                Int.self,
                forKey: .operatingSystemMajorVersion
            ),
            operatingSystemMinorVersion: try container.decode(
                Int.self,
                forKey: .operatingSystemMinorVersion
            ),
            operatingSystemPatchVersion: try container.decodeIfPresent(
                Int.self,
                forKey: .operatingSystemPatchVersion
            ) ?? 0,
            darwinVersion: try container.decodeIfPresent(
                String.self,
                forKey: .darwinVersion
            ),
            architecture: architecture,
            binaryUUID: try container.decodeIfPresent(
                String.self,
                forKey: .binaryUUID
            ),
            binarySHA256: try container.decodeIfPresent(
                String.self,
                forKey: .binarySHA256
            ),
            binarySHA256Scope: try container.decodeIfPresent(
                DiagnosticBinarySHA256Scope.self,
                forKey: .binarySHA256Scope
            )
        )
    }

    public static var current: Self {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let buildArchitecture = bundleString(
            forInfoDictionaryKey: "NoonmarkBuildArchitecture"
        )
        return Self(
            version: version,
            build: build,
            commitSHA: bundleString(
                forInfoDictionaryKey: "NoonmarkGitCommit"
            ),
            buildDate: bundleString(
                forInfoDictionaryKey: "NoonmarkBuildDate"
            ),
            runtime: bundleString(
                forInfoDictionaryKey: "NoonmarkRuntime"
            ),
            minimumOSVersion: bundleString(
                forInfoDictionaryKey: "NoonmarkMinimumOSVersion"
            ),
            buildArchitecture: buildArchitecture,
            operatingSystemMajorVersion: os.majorVersion,
            operatingSystemMinorVersion: os.minorVersion,
            operatingSystemPatchVersion: os.patchVersion,
            darwinVersion: currentDarwinVersion,
            architecture: currentArchitecture,
            binaryUUID: bundleString(
                forInfoDictionaryKey: "NoonmarkBinaryUUID"
            ),
            binarySHA256: bundleString(
                forInfoDictionaryKey: "NoonmarkBinarySHA256"
            ),
            binarySHA256Scope: bundleString(
                forInfoDictionaryKey: "NoonmarkBinarySHA256Scope"
            ).flatMap(DiagnosticBinarySHA256Scope.init(rawValue:))
        )
    }

    public static let testFixture = Self(
        version: "0.1.0",
        build: "1",
        buildArchitecture: "test",
        operatingSystemMajorVersion: 14,
        operatingSystemMinorVersion: 0,
        operatingSystemPatchVersion: 0,
        darwinVersion: "23.0.0",
        architecture: "test"
    )

    private static func bundleString(
        forInfoDictionaryKey key: String
    ) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var currentDarwinVersion: String? {
        var information = utsname()
        guard uname(&information) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: information.release)
        let release = withUnsafePointer(to: &information.release) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                String(cString: $0)
            }
        }
        return safeDarwinVersion(release)
    }

    private static func safeBuildValue(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        let scalars = value.unicodeScalars.prefix(128).filter {
            allowed.contains($0)
        }
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? "unknown" : result
    }

    private static func safeCommitSHA(_ value: String) -> String? {
        safeHexDigest(value, allowedLengths: [40, 64])
    }

    private static func safeBinarySHA256(_ value: String) -> String? {
        safeHexDigest(value, allowedLengths: [64])
    }

    private static func safeHexDigest(
        _ value: String,
        allowedLengths: Set<Int>
    ) -> String? {
        guard allowedLengths.contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.decimalDigits.contains(scalar)
                          || "abcdefABCDEF".unicodeScalars.contains(scalar)
                  )
              })
        else { return nil }
        return value.lowercased()
    }

    private static func safeBuildDate(_ value: String) -> String? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value
        else { return nil }
        return value
    }

    private static func safeDarwinVersion(_ value: String) -> String? {
        safeDottedVersion(value)
    }

    private static func safeRuntime(_ value: String) -> String? {
        value == "Swift-native" ? value : nil
    }

    private static func safeDottedVersion(_ value: String) -> String? {
        guard value.utf8.count <= 32 else { return nil }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (2 ... 4).contains(components.count),
              components.allSatisfy({ component in
                  component.isEmpty == false
                      && component.count <= 4
                      && component.allSatisfy(\.isNumber)
              })
        else { return nil }
        return value
    }

    private static func safeBinaryUUIDSet(_ value: String) -> String? {
        guard value.isEmpty == false, value.utf8.count <= 512 else {
            return nil
        }
        let entries = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        var slices: [(architecture: String, uuid: UUID)] = []
        var architectures = Set<String>()
        for entry in entries {
            let pair = entry.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2 else { return nil }
            let architecture = pair[0].lowercased()
            guard ["arm64", "arm64e", "x86_64"].contains(architecture),
                  architectures.insert(architecture).inserted,
                  let uuid = UUID(uuidString: String(pair[1]))
            else { return nil }
            slices.append((architecture, uuid))
        }
        return slices
            .sorted { $0.architecture < $1.architecture }
            .map { "\($0.architecture):\($0.uuid.uuidString)" }
            .joined(separator: ",")
    }
}

public struct DiagnosticStorageConfiguration: Equatable, Sendable {
    public let maximumPersistentBytes: Int64
    public let eventSegmentCount: Int
    public let eventSegmentPayloadBytes: Int64
    public let maximumEventBytes: Int
    public let metricCacheBytes: Int64
    public let maximumMetricPayloadBytes: Int
    public let retentionInterval: TimeInterval
    public let maximumQueuedEvents: Int
    public let maximumQueuedBytes: Int

    public init(
        maximumPersistentBytes: Int64 = 4 * 1024 * 1024,
        eventSegmentCount: Int = 4,
        eventSegmentPayloadBytes: Int64 = 512 * 1024,
        maximumEventBytes: Int = 4 * 1024,
        metricCacheBytes: Int64 = 768 * 1024,
        maximumMetricPayloadBytes: Int = 256 * 1024,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        maximumQueuedEvents: Int = 256,
        maximumQueuedBytes: Int = 256 * 1024
    ) {
        self.maximumPersistentBytes = max(32 * 1024, maximumPersistentBytes)
        self.eventSegmentCount = max(1, min(16, eventSegmentCount))
        self.eventSegmentPayloadBytes = max(4 * 1024, eventSegmentPayloadBytes)
        self.maximumEventBytes = max(512, maximumEventBytes)
        self.metricCacheBytes = max(0, metricCacheBytes)
        self.maximumMetricPayloadBytes = max(0, maximumMetricPayloadBytes)
        self.retentionInterval = max(60, retentionInterval)
        self.maximumQueuedEvents = max(1, maximumQueuedEvents)
        self.maximumQueuedBytes = max(1024, maximumQueuedBytes)
    }

    public static let production = Self()
}

public struct DiagnosticActiveOperation: Codable, Equatable, Sendable {
    public let id: DiagnosticOperationID
    public var incidentID: DiagnosticIncidentID?
    public let kind: DiagnosticOperationKind
    public let endpoint: DiagnosticEndpoint
    public let startedAt: Date
    public var updatedAt: Date
    public var lastStage: DiagnosticOperationStage?
    public var lastProgress: DiagnosticProgress?
}

public enum DiagnosticOperationOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case interrupted
}

public struct DiagnosticOperationCapsule: Codable, Equatable, Sendable {
    public let operationID: DiagnosticOperationID
    public let incidentID: DiagnosticIncidentID?
    public let kind: DiagnosticOperationKind
    public let endpoint: DiagnosticEndpoint
    public let startedAt: Date
    public let finishedAt: Date
    public let lastStage: DiagnosticOperationStage?
    public let lastProgress: DiagnosticProgress?
    public let outcome: DiagnosticOperationOutcome
    public let failure: DiagnosticFailure?
}

public struct DiagnosticHealth: Codable, Equatable, Sendable {
    public let allocatedBytes: Int64
    public let maximumObservedAllocatedBytes: Int64
    public let logicalBytes: Int64
    public let recordCount: Int
    public let oldestRecordAt: Date?
    public let newestRecordAt: Date?
    public let activeOperationCount: Int
    public let operationCapsuleCount: Int
    public let metricPayloadCount: Int
    public let droppedRecordCount: Int
    public let droppedCriticalRecordCount: Int
    public let compactedCriticalEvidenceCount: Int
    public let evictedMetricPayloadCount: Int
    public let corruptRecordCount: Int
    public let oversizedEventCount: Int
    public let oversizedMetricPayloadCount: Int
    public let fileSinkDisabled: Bool
}

public struct DiagnosticExportPreview: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordCount: Int
    public let activeOperationCount: Int
    public let operationCapsuleCount: Int
    public let metricPayloadCount: Int
    public let oldestRecordAt: Date?
    public let newestRecordAt: Date?
    public let allocatedBytes: Int64
    public let estimatedExportBytes: Int64
}

public struct DiagnosticExportManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appIdentity: DiagnosticAppIdentity
    public let recordCount: Int
    public let activeOperationCount: Int
    public let operationCapsuleCount: Int
    public let metricPayloadCount: Int
    public let oldestRecordAt: Date?
    public let newestRecordAt: Date?
    public let droppedRecordCount: Int
    public let droppedCriticalRecordCount: Int
    public let compactedCriticalEvidenceCount: Int
    public let evictedMetricPayloadCount: Int
    public let corruptRecordCount: Int
    public let oversizedEventCount: Int
    public let oversizedMetricPayloadCount: Int
    public let maximumObservedAllocatedBytes: Int64
    public let redactionVersion: Int
    public let collectionWasPartial: Bool
}

public struct DiagnosticMetricAttachment: Codable, Equatable, Sendable {
    public let receivedAt: Date
    public let summary: MetricKitPayloadSummary
    public let sanitizedJSON: Data?
    public let redactionVersion: Int
}

public struct DiagnosticExportPackage: Codable, Equatable, Sendable {
    public let manifest: DiagnosticExportManifest
    public let records: [RecordedEvidence]
    public let activeOperations: [DiagnosticActiveOperation]
    public let operationCapsules: [DiagnosticOperationCapsule]
    public let metricAttachments: [DiagnosticMetricAttachment]
}

public struct DiagnosticExportReceipt: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let sha256: String
    public let recordCount: Int
    public let generatedAt: Date
}
