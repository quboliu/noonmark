import CryptoKit
import Foundation
import NoonmarkSync

enum SQLiteSyncBaselineManifestState: String, Codable {
    case pending
    case established
}

struct SQLiteSyncBaselineJournalExpectation:
    Codable,
    Equatable
{
    let journalEntryID: UUID
    let evidenceDigest: String

    init(entry: SyncJournalEntry) {
        journalEntryID = entry.id
        evidenceDigest = Self.digest(entry)
    }

    func matches(_ entry: SyncJournalEntry) -> Bool {
        journalEntryID == entry.id
            && evidenceDigest == Self.digest(entry)
    }

    private static func digest(_ entry: SyncJournalEntry) -> String {
        var evidence = Data("noonmark.sync-baseline-journal.v1".utf8)
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) {
                evidence.append(contentsOf: $0)
            }
            evidence.append(data)
        }
        append(Data(entry.id.uuidString.utf8))
        append(Data(entry.entityType.rawValue.utf8))
        append(Data(entry.entityID.utf8))
        append(Data(entry.operation.rawValue.utf8))
        var changedAtBits = entry.changedAt.timeIntervalSinceReferenceDate
            .bitPattern.bigEndian
        withUnsafeBytes(of: &changedAtBits) {
            append(Data($0))
        }
        append(Data(entry.deviceID.rawValue.utf8))
        append(entry.recordPayload ?? Data())
        return SHA256.hash(data: evidence)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SQLiteSyncBaselineManifest: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let expectations: [SQLiteSyncBaselineJournalExpectation]
    let state: SQLiteSyncBaselineManifestState
    let establishedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date,
        entries: [SyncJournalEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        expectations = entries
            .map(SQLiteSyncBaselineJournalExpectation.init)
            .sorted {
                $0.journalEntryID.uuidString
                    < $1.journalEntryID.uuidString
            }
        state = .pending
        establishedAt = nil
    }

    private init(
        id: UUID,
        createdAt: Date,
        expectations: [SQLiteSyncBaselineJournalExpectation],
        state: SQLiteSyncBaselineManifestState,
        establishedAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expectations = expectations
        self.state = state
        self.establishedAt = establishedAt
    }

    func established(at date: Date) -> Self {
        Self(
            id: id,
            createdAt: createdAt,
            expectations: expectations,
            state: .established,
            establishedAt: date
        )
    }

    func validate(against entries: [SyncJournalEntry]) -> Bool {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              expectations.isEmpty == false,
              Set(expectations.map(\.journalEntryID)).count
              == expectations.count,
              expectations == expectations.sorted(by: {
                  $0.journalEntryID.uuidString
                      < $1.journalEntryID.uuidString
              }),
              establishedAt?.timeIntervalSinceReferenceDate
              .isFinite ?? true,
              state == .established
              ? establishedAt != nil
              : establishedAt == nil
        else {
            return false
        }
        let entriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
        return expectations.allSatisfy {
            guard let entry = entriesByID[$0.journalEntryID] else {
                return false
            }
            return $0.matches(entry)
        }
    }

    var expectedJournalEntryIDs: Set<UUID> {
        Set(expectations.map(\.journalEntryID))
    }

    func metadata(key: String, updatedAt: Date) throws
        -> SyncMetadataEntry
    {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return SyncMetadataEntry(
            key: key,
            value: try encoder.encode(self),
            updatedAt: updatedAt
        )
    }

    static func decode(_ metadata: SyncMetadataEntry) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: metadata.value)
    }
}
