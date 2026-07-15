import CloudKit
import CryptoKit
import Foundation

public enum CloudKitSyncRecordCodecError: Error, Equatable, Sendable {
    case unexpectedRecordType
    case unexpectedRecordZone
    case unexpectedFieldSet
    case unsupportedFormatVersion
    case missingRequiredField(String)
    case digestMismatch
    case invalidWirePayload
    case noncanonicalWirePayload
    case syncRecordIDMismatch
    case recordNameMismatch
}

extension CloudKitSyncRecordCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unexpectedRecordType:
            "CloudKit record type is not supported."
        case .unexpectedRecordZone:
            "CloudKit record belongs to an unexpected zone."
        case .unexpectedFieldSet:
            "CloudKit record contains an unexpected field set."
        case .unsupportedFormatVersion:
            "CloudKit record format version is not supported."
        case let .missingRequiredField(field):
            "CloudKit record is missing required field \(field)."
        case .digestMismatch:
            "CloudKit record payload digest does not match."
        case .invalidWirePayload:
            "CloudKit record payload cannot be decoded."
        case .noncanonicalWirePayload:
            "CloudKit record payload is not canonical."
        case .syncRecordIDMismatch:
            "CloudKit record payload identity does not match its metadata."
        case .recordNameMismatch:
            "CloudKit record name does not match its payload identity."
        }
    }
}

public struct CloudKitSyncRecordCodec: Sendable {
    public static let recordType = "NoonmarkSyncRecordV1"
    public static let formatVersion: Int64 = 1

    private enum Field {
        static let formatVersion = "formatVersion"
        static let syncRecordID = "syncRecordID"
        static let wirePayload = "wirePayload"
        static let wireSHA256 = "wireSHA256"

        static let all: Set<String> = [
            formatVersion,
            syncRecordID,
            wirePayload,
            wireSHA256
        ]
    }

    public let zoneID: CKRecordZone.ID

    public init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }

    public func recordID(for syncRecordID: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "sync-\(sha256(Data(syncRecordID.rawValue.utf8)))",
            zoneID: zoneID
        )
    }

    public func encode(
        _ syncRecord: SyncRecord,
        reusing serverRecord: CKRecord? = nil
    ) throws -> CKRecord {
        let expectedRecordID = recordID(for: syncRecord.id)
        let cloudRecord: CKRecord
        if let serverRecord {
            guard serverRecord.recordType == Self.recordType else {
                throw CloudKitSyncRecordCodecError.unexpectedRecordType
            }
            guard serverRecord.recordID == expectedRecordID else {
                throw CloudKitSyncRecordCodecError.recordNameMismatch
            }
            cloudRecord = serverRecord
        } else {
            cloudRecord = CKRecord(
                recordType: Self.recordType,
                recordID: expectedRecordID
            )
        }

        let wirePayload = try canonicalData(for: syncRecord)
        cloudRecord[Field.formatVersion] = Self.formatVersion as CKRecordValue
        cloudRecord[Field.syncRecordID] = syncRecord.id.rawValue as CKRecordValue
        cloudRecord[Field.wirePayload] = wirePayload as CKRecordValue
        cloudRecord[Field.wireSHA256] = sha256(wirePayload) as CKRecordValue
        return cloudRecord
    }

    public func decode(_ cloudRecord: CKRecord) throws -> SyncRecord {
        try validateEnvelope(cloudRecord)
        let formatVersion: Int64 = try requiredField(
            Field.formatVersion,
            in: cloudRecord
        )
        let syncRecordID: String = try requiredField(
            Field.syncRecordID,
            in: cloudRecord
        )
        let wirePayload: Data = try requiredField(
            Field.wirePayload,
            in: cloudRecord
        )
        let expectedDigest: String = try requiredField(
            Field.wireSHA256,
            in: cloudRecord
        )
        guard formatVersion == Self.formatVersion else {
            throw CloudKitSyncRecordCodecError.unsupportedFormatVersion
        }
        guard sha256(wirePayload) == expectedDigest else {
            throw CloudKitSyncRecordCodecError.digestMismatch
        }

        let syncRecord = try decodeWirePayload(wirePayload)
        guard try canonicalData(for: syncRecord) == wirePayload else {
            throw CloudKitSyncRecordCodecError.noncanonicalWirePayload
        }
        guard syncRecord.id.rawValue == syncRecordID else {
            throw CloudKitSyncRecordCodecError.syncRecordIDMismatch
        }
        guard cloudRecord.recordID == recordID(for: syncRecord.id) else {
            throw CloudKitSyncRecordCodecError.recordNameMismatch
        }
        return syncRecord
    }

    private func validateEnvelope(_ cloudRecord: CKRecord) throws {
        guard cloudRecord.recordType == Self.recordType else {
            throw CloudKitSyncRecordCodecError.unexpectedRecordType
        }
        guard cloudRecord.recordID.zoneID == zoneID else {
            throw CloudKitSyncRecordCodecError.unexpectedRecordZone
        }
        guard Set(cloudRecord.allKeys()) == Field.all else {
            throw CloudKitSyncRecordCodecError.unexpectedFieldSet
        }
    }

    private func requiredField<Value>(
        _ field: String,
        in cloudRecord: CKRecord
    ) throws -> Value {
        guard let value = cloudRecord[field] as? Value else {
            throw CloudKitSyncRecordCodecError.missingRequiredField(
                field
            )
        }
        return value
    }

    private func decodeWirePayload(_ wirePayload: Data) throws -> SyncRecord {
        do {
            return try JSONDecoder().decode(SyncRecord.self, from: wirePayload)
        } catch {
            throw CloudKitSyncRecordCodecError.invalidWirePayload
        }
    }

    private func canonicalData(for syncRecord: SyncRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(syncRecord)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum CloudKitAccountAvailability: String, Codable, Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    public init(_ status: CKAccountStatus) {
        switch status {
        case .available:
            self = .available
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable
        case .couldNotDetermine:
            self = .couldNotDetermine
        @unknown default:
            self = .couldNotDetermine
        }
    }

    public var canSync: Bool { self == .available }
}
