import CryptoKit
import Foundation

/// SHA-256 identity of every exact wire fact used by `SyncRecord.exactlyMatches`.
/// Logical record IDs are intentionally insufficient because current records may
/// carry several distinct versions and immutable collisions may carry several
/// terminally rejected variants under the same identity.
public struct SyncRecordEvidenceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(record: SyncRecord) {
        var evidence = Data()
        func append(_ value: Data) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { evidence.append(contentsOf: $0) }
            evidence.append(value)
        }
        func append(_ value: String) {
            append(Data(value.utf8))
        }

        append("noonmark.sync-record.exact-evidence.v1")
        append(record.id.rawValue)
        append(record.entityType.rawValue)
        append(record.entityID)
        append(record.operation.rawValue)
        var modifiedAtBits = record.modifiedAt.timeIntervalSinceReferenceDate
            .bitPattern.bigEndian
        withUnsafeBytes(of: &modifiedAtBits) { append(Data($0)) }
        append(record.modifiedByDeviceID.rawValue)
        append(record.payload)
        var witnessCount = UInt64(record.reactivationWitnesses.count).bigEndian
        withUnsafeBytes(of: &witnessCount) {
            evidence.append(contentsOf: $0)
        }
        for witness in record.reactivationWitnesses {
            append(witness)
        }

        rawValue = SHA256.hash(data: evidence)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let validated = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "sync record evidence ID is not lowercase SHA-256"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    private static func isValid(_ rawValue: String) -> Bool {
        rawValue.utf8.count == 64
            && rawValue.utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
    }
}

public struct SyncRecordEvidence: Equatable, Sendable {
    public let id: SyncRecordEvidenceID
    public let record: SyncRecord

    public init(record: SyncRecord) {
        id = SyncRecordEvidenceID(record: record)
        self.record = record
    }
}

/// Records which contributed to one canonical current record. A synthetic
/// canonical fact may differ exactly from every source while retaining all of
/// their evidence identities here.
public struct SyncRecordProvenanceGroup: Equatable, Sendable {
    public let canonicalRecord: SyncRecord
    public let canonicalEvidenceID: SyncRecordEvidenceID
    public let contributingEvidenceIDs: [SyncRecordEvidenceID]
    public let supersededEvidenceIDs: [SyncRecordEvidenceID]

    public var sourceEvidenceIDs: [SyncRecordEvidenceID] {
        (contributingEvidenceIDs + supersededEvidenceIDs).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    public init(
        canonicalRecord: SyncRecord,
        sourceEvidenceIDs: [SyncRecordEvidenceID]
    ) {
        let canonicalEvidenceID = SyncRecordEvidenceID(record: canonicalRecord)
        let uniqueSources = Set(sourceEvidenceIDs)
        let canonicalIsAnExactSource = uniqueSources.contains(
            canonicalEvidenceID
        )
        self.init(
            canonicalRecord: canonicalRecord,
            contributingEvidenceIDs: canonicalIsAnExactSource
                ? [canonicalEvidenceID]
                : Array(uniqueSources),
            supersededEvidenceIDs: canonicalIsAnExactSource
                ? Array(uniqueSources.subtracting([canonicalEvidenceID]))
                : []
        )
    }

    public init(
        canonicalRecord: SyncRecord,
        contributingEvidenceIDs: [SyncRecordEvidenceID],
        supersededEvidenceIDs: [SyncRecordEvidenceID]
    ) {
        self.canonicalRecord = canonicalRecord
        canonicalEvidenceID = SyncRecordEvidenceID(record: canonicalRecord)
        let contributors = Set(contributingEvidenceIDs)
        let superseded = Set(supersededEvidenceIDs)
            .subtracting(contributors)
        self.contributingEvidenceIDs = contributors.sorted {
            $0.rawValue < $1.rawValue
        }
        self.supersededEvidenceIDs = superseded.sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public enum SyncRecordOutcomeDisposition: String, Codable, Equatable, Sendable {
    case merged
    case ignored
    case waiting
    case conflict
}

public struct SyncRecordMergeOutcome: Equatable, Sendable {
    public let evidence: SyncRecordEvidence
    public let canonicalEvidenceID: SyncRecordEvidenceID?
    public let disposition: SyncRecordOutcomeDisposition
    public let dependencies: [SyncRecordDependency]
    public let conflictID: UUID?

    public init(
        evidence: SyncRecordEvidence,
        canonicalEvidenceID: SyncRecordEvidenceID?,
        disposition: SyncRecordOutcomeDisposition,
        dependencies: [SyncRecordDependency] = [],
        conflictID: UUID? = nil
    ) {
        self.evidence = evidence
        self.canonicalEvidenceID = canonicalEvidenceID
        self.disposition = disposition
        self.dependencies = dependencies
        self.conflictID = conflictID
    }
}

enum SyncRecordEvidenceCanonicalizer {
    struct Group {
        let recordID: SyncRecordID
        let evidence: [SyncRecordEvidence]
    }

    static func uniqueEvidence(
        _ records: [SyncRecord]
    ) -> [SyncRecordEvidence] {
        var seen: Set<SyncRecordEvidenceID> = []
        return records.compactMap { record in
            let evidence = SyncRecordEvidence(record: record)
            return seen.insert(evidence.id).inserted ? evidence : nil
        }
    }

    static func groups(
        _ records: [SyncRecord]
    ) -> [Group] {
        var orderedIDs: [SyncRecordID] = []
        var byID: [SyncRecordID: [SyncRecord]] = [:]
        for record in records {
            if byID[record.id] == nil {
                orderedIDs.append(record.id)
            }
            byID[record.id, default: []].append(record)
        }
        return orderedIDs.compactMap { recordID in
            guard let records = byID[recordID] else { return nil }
            return Group(
                recordID: recordID,
                evidence: uniqueEvidence(records).sorted {
                    $0.id.rawValue < $1.id.rawValue
                }
            )
        }
    }
}
