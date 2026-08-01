import Foundation

public struct DiagnosticAppIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let operatingSystemMajorVersion: Int
    public let operatingSystemMinorVersion: Int
    public let architecture: String
    public let binaryUUID: String?
    public let binarySHA256: String?

    init(
        version: String,
        build: String,
        operatingSystemMajorVersion: Int,
        operatingSystemMinorVersion: Int,
        architecture: String,
        binaryUUID: String? = nil,
        binarySHA256: String? = nil
    ) {
        self.version = Self.safeBuildValue(version)
        self.build = Self.safeBuildValue(build)
        self.operatingSystemMajorVersion = max(0, operatingSystemMajorVersion)
        self.operatingSystemMinorVersion = max(0, operatingSystemMinorVersion)
        self.architecture = Self.safeBuildValue(architecture)
        self.binaryUUID = binaryUUID.map(Self.safeBuildValue)
        self.binarySHA256 = binarySHA256.map(Self.safeBuildValue)
    }

    public static var current: Self {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            version: version,
            build: build,
            operatingSystemMajorVersion: os.majorVersion,
            operatingSystemMinorVersion: os.minorVersion,
            architecture: currentArchitecture
        )
    }

    public static let testFixture = Self(
        version: "0.1.0",
        build: "1",
        operatingSystemMajorVersion: 14,
        operatingSystemMinorVersion: 0,
        architecture: "test"
    )

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
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
        maximumPersistentBytes: Int64 = 4 * 1_024 * 1_024,
        eventSegmentCount: Int = 4,
        eventSegmentPayloadBytes: Int64 = 512 * 1_024,
        maximumEventBytes: Int = 4 * 1_024,
        metricCacheBytes: Int64 = 768 * 1_024,
        maximumMetricPayloadBytes: Int = 256 * 1_024,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        maximumQueuedEvents: Int = 256,
        maximumQueuedBytes: Int = 256 * 1_024
    ) {
        self.maximumPersistentBytes = max(32 * 1_024, maximumPersistentBytes)
        self.eventSegmentCount = max(1, min(16, eventSegmentCount))
        self.eventSegmentPayloadBytes = max(4 * 1_024, eventSegmentPayloadBytes)
        self.maximumEventBytes = max(512, maximumEventBytes)
        self.metricCacheBytes = max(0, metricCacheBytes)
        self.maximumMetricPayloadBytes = max(0, maximumMetricPayloadBytes)
        self.retentionInterval = max(60, retentionInterval)
        self.maximumQueuedEvents = max(1, maximumQueuedEvents)
        self.maximumQueuedBytes = max(1_024, maximumQueuedBytes)
    }

    public static let production = Self()
}

public struct DiagnosticActiveOperation: Codable, Equatable, Sendable {
    public let id: DiagnosticOperationID
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
    public let logicalBytes: Int64
    public let recordCount: Int
    public let oldestRecordAt: Date?
    public let newestRecordAt: Date?
    public let activeOperationCount: Int
    public let operationCapsuleCount: Int
    public let metricPayloadCount: Int
    public let droppedRecordCount: Int
    public let corruptRecordCount: Int
    public let oversizedEventCount: Int
    public let oversizedMetricPayloadCount: Int
    public let fileSinkDisabled: Bool
}

public struct DiagnosticExportPreview: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordCount: Int
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
    public let operationCapsuleCount: Int
    public let metricPayloadCount: Int
    public let oldestRecordAt: Date?
    public let newestRecordAt: Date?
    public let droppedRecordCount: Int
    public let corruptRecordCount: Int
    public let oversizedEventCount: Int
    public let oversizedMetricPayloadCount: Int
    public let collectionWasPartial: Bool
}

public struct DiagnosticMetricAttachment: Codable, Equatable, Sendable {
    public let receivedAt: Date
    public let payload: Data
}

public struct DiagnosticExportPackage: Codable, Equatable, Sendable {
    public let manifest: DiagnosticExportManifest
    public let records: [RecordedEvidence]
    public let operationCapsules: [DiagnosticOperationCapsule]
    public let metricAttachments: [DiagnosticMetricAttachment]
}

public struct DiagnosticExportReceipt: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let sha256: String
    public let recordCount: Int
    public let generatedAt: Date
}
