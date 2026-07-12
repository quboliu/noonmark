import CryptoKit
import Foundation

public protocol ZhulongSidecarKeySource: Sendable {
    func loadOrCreateKey() throws -> Data
}

public enum ZhulongSidecarRepositoryError: Error, Equatable {
    case invalidKeyLength
    case unsupportedEnvelope
    case invalidCiphertext
    case missingSession
    case invalidLegacyProvenance
}

public struct EncryptedFileZhulongSessionRepository: ZhulongSessionRepository, @unchecked Sendable {
    private static let magic = Data("NOONMARK-ZHULONG-SIDECAR".utf8)
    private static let formatVersion: UInt8 = 6
    private static let migratedLegacyFormatVersion: UInt8 = 7
    private static let planningOutputFormatVersion: UInt8 = 4
    private static let migratedPlanningOutputFormatVersion: UInt8 = 5
    private static let planningBriefFormatVersion: UInt8 = 3
    private static let workspaceFormatVersion: UInt8 = 2
    private static let legacyFormatVersion: UInt8 = 1

    public let directoryURL: URL
    private let keySource: any ZhulongSidecarKeySource
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        keySource: any ZhulongSidecarKeySource,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.keySource = keySource
        self.fileManager = fileManager
    }

    public func fileURL(for id: ZhulongSessionID) -> URL {
        directoryURL.appendingPathComponent("\(id.description).zhs", isDirectory: false)
    }

    public func save(_ session: ZhulongSession) throws {
        let containsLegacyPlanning = session.providerSends.contains {
            if case .migratedLegacyPlanning = $0.purpose { return true }
            return false
        }
        guard containsLegacyPlanning == false || session.hasAuthenticatedLegacyPlanningProvenance else {
            throw ZhulongSidecarRepositoryError.invalidLegacyProvenance
        }
        try saveRecord(
            ZhulongSessionRecord(session),
            version: containsLegacyPlanning
                ? Self.migratedLegacyFormatVersion
                : Self.formatVersion
        )
    }

    public func load(_ id: ZhulongSessionID) throws -> ZhulongSession {
        let fileURL = fileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ZhulongSidecarRepositoryError.missingSession
        }
        let envelope = try Data(contentsOf: fileURL)
        let decodedEnvelope = try decodeEnvelope(envelope)
        let key = try symmetricKey()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: decodedEnvelope.ciphertext)
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let plaintext = try decrypt(
            sealedBox,
            using: key,
            id: id,
            version: decodedEnvelope.version
        )
        let record: ZhulongSessionRecord
        let allowsMigratedLegacyPlanning: Bool
        switch decodedEnvelope.version {
        case Self.legacyFormatVersion:
            let legacy = try decoder.decode(ZhulongSessionRecordV1.self, from: plaintext)
            record = ZhulongSessionRecord(migrating: legacy)
            allowsMigratedLegacyPlanning = false
        case Self.workspaceFormatVersion:
            let workspace = try decoder.decode(ZhulongSessionRecordV2.self, from: plaintext)
            record = ZhulongSessionRecord(migrating: workspace)
            allowsMigratedLegacyPlanning = false
        case Self.planningBriefFormatVersion:
            let planningBrief = try decoder.decode(ZhulongSessionRecordV3.self, from: plaintext)
            record = ZhulongSessionRecord(migrating: planningBrief)
            allowsMigratedLegacyPlanning = true
        case Self.planningOutputFormatVersion, Self.migratedPlanningOutputFormatVersion:
            let planningOutput = try decoder.decode(ZhulongSessionRecordV4.self, from: plaintext)
            record = ZhulongSessionRecord(migrating: planningOutput)
            allowsMigratedLegacyPlanning = decodedEnvelope.version ==
                Self.migratedPlanningOutputFormatVersion
        case Self.formatVersion, Self.migratedLegacyFormatVersion:
            record = try decoder.decode(ZhulongSessionRecord.self, from: plaintext)
            allowsMigratedLegacyPlanning = decodedEnvelope.version == Self.migratedLegacyFormatVersion
        default:
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        return try record.restore(
            expectedID: id,
            allowsMigratedLegacyPlanning: allowsMigratedLegacyPlanning
        )
    }

    func saveRecordForTesting(_ record: ZhulongSessionRecord) throws {
        try saveRecord(record, version: Self.formatVersion)
    }

    func saveLegacySessionForTesting(_ session: ZhulongSession) throws {
        try savePlaintext(
            encoder.encode(ZhulongSessionRecordV1(session)),
            id: session.id,
            version: Self.legacyFormatVersion,
            usesLegacyAuthentication: true
        )
    }

    func saveVersionTwoSessionForTesting(_ session: ZhulongSession) throws {
        try savePlaintext(
            encoder.encode(ZhulongSessionRecordV2(session)),
            id: session.id,
            version: Self.workspaceFormatVersion,
            usesLegacyAuthentication: true
        )
    }

    func saveVersionThreeSessionForTesting(_ session: ZhulongSession) throws {
        try saveVersionThreeRecordForTesting(ZhulongSessionRecordV3(session))
    }

    func saveVersionThreeRecordForTesting(_ record: ZhulongSessionRecordV3) throws {
        try savePlaintext(
            encoder.encode(record),
            id: record.id,
            version: Self.planningBriefFormatVersion
        )
    }

    func saveVersionFourSessionForTesting(_ session: ZhulongSession) throws {
        try savePlaintext(
            encoder.encode(ZhulongSessionRecordV4(session)),
            id: session.id,
            version: Self.planningOutputFormatVersion
        )
    }

    func saveCurrentSessionWithLegacyAuthenticationForTesting(
        _ session: ZhulongSession
    ) throws {
        try savePlaintext(
            encoder.encode(ZhulongSessionRecord(session)),
            id: session.id,
            version: Self.formatVersion,
            usesLegacyAuthentication: true
        )
    }

    private func saveRecord(_ record: ZhulongSessionRecord, version: UInt8) throws {
        try savePlaintext(
            encoder.encode(record),
            id: record.id,
            version: version
        )
    }

    private func savePlaintext(
        _ plaintext: Data,
        id: ZhulongSessionID,
        version: UInt8,
        usesLegacyAuthentication: Bool = false
    ) throws {
        let key = try symmetricKey()
        let authentication = usesLegacyAuthentication
            ? legacyAuthenticatedData(for: id)
            : authenticatedData(for: id, version: version)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authentication
        )
        guard let combined = sealedBox.combined else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }

        var envelope = Self.magic
        envelope.append(version)
        envelope.append(combined)

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let fileURL = fileURL(for: id)
        try envelope.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func decodeEnvelope(_ envelope: Data) throws -> (version: UInt8, ciphertext: Data) {
        let headerSize = Self.magic.count + 1
        guard envelope.count > headerSize,
              envelope.prefix(Self.magic.count) == Self.magic
        else {
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        let version = envelope[Self.magic.count]
        guard version == Self.legacyFormatVersion ||
            version == Self.workspaceFormatVersion ||
            version == Self.planningBriefFormatVersion ||
            version == Self.planningOutputFormatVersion ||
            version == Self.migratedPlanningOutputFormatVersion ||
            version == Self.formatVersion ||
            version == Self.migratedLegacyFormatVersion
        else {
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        return (version, envelope.dropFirst(headerSize))
    }

    private func symmetricKey() throws -> SymmetricKey {
        let keyData = try keySource.loadOrCreateKey()
        guard keyData.count == 32 else {
            throw ZhulongSidecarRepositoryError.invalidKeyLength
        }
        return SymmetricKey(data: keyData)
    }

    private func decrypt(
        _ sealedBox: AES.GCM.SealedBox,
        using key: SymmetricKey,
        id: ZhulongSessionID,
        version: UInt8
    ) throws -> Data {
        do {
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(for: id, version: version)
            )
        } catch {
            // Existing v1-v3 files used session-only AAD. Their authenticated JSON
            // shape must match the declared version before migration can continue.
            guard version <= Self.planningBriefFormatVersion else {
                throw ZhulongSidecarRepositoryError.invalidCiphertext
            }
            do {
                let plaintext = try AES.GCM.open(
                    sealedBox,
                    using: key,
                    authenticating: legacyAuthenticatedData(for: id)
                )
                try validateLegacySchema(plaintext, version: version)
                return plaintext
            } catch {
                throw ZhulongSidecarRepositoryError.invalidCiphertext
            }
        }
    }

    private func validateLegacySchema(_ plaintext: Data, version: UInt8) throws {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext),
              let record = object as? [String: Any]
        else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let commonKeys = Set([
            "id", "primaryIntent", "proposedScopes", "phase", "authorizations",
            "providerSends", "events"
        ])
        let optionalKeys = Set(["draftVersion"])
        let requiredKeys: Set<String>
        let allowedKeys: Set<String>
        switch version {
        case Self.legacyFormatVersion:
            requiredKeys = commonKeys
            allowedKeys = commonKeys.union(optionalKeys)
        case Self.workspaceFormatVersion:
            let workspaceKeys = Set(["workspaceStatus", "entries"])
            requiredKeys = commonKeys.union(workspaceKeys)
            allowedKeys = requiredKeys.union(optionalKeys)
        case Self.planningBriefFormatVersion:
            let planningKeys = Set([
                "workspaceStatus", "entries", "planningBriefs", "planningBriefReviews",
                "planningBriefInvalidations", "planningDelegations",
                "planningDelegationConsumptions", "planningDelegationInvalidations",
                "planningRunInvalidations"
            ])
            requiredKeys = commonKeys.union(planningKeys)
            allowedKeys = requiredKeys.union(optionalKeys)
        case Self.planningOutputFormatVersion, Self.migratedPlanningOutputFormatVersion:
            let planningOutputKeys = Set([
                "workspaceStatus", "entries", "planningBriefs", "planningBriefReviews",
                "planningBriefInvalidations", "planningDelegations",
                "planningDelegationConsumptions", "planningDelegationInvalidations",
                "planningRunInvalidations", "decisionGates", "decisionGateResolutions",
                "planArtifacts"
            ])
            requiredKeys = commonKeys.union(planningOutputKeys)
            allowedKeys = requiredKeys.union(optionalKeys)
        case Self.formatVersion, Self.migratedLegacyFormatVersion:
            let todoLedgerKeys = Set([
                "workspaceStatus", "entries", "planningBriefs", "planningBriefReviews",
                "planningBriefInvalidations", "planningDelegations",
                "planningDelegationConsumptions", "planningDelegationInvalidations",
                "planningRunInvalidations", "decisionGates", "decisionGateResolutions",
                "planArtifacts", "todoDiffDrafts", "todoWriteAuthorizations",
                "todoApplyReceipts"
            ])
            requiredKeys = commonKeys.union(todoLedgerKeys)
            allowedKeys = requiredKeys.union(optionalKeys)
        default:
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        let actualKeys = Set(record.keys)
        guard requiredKeys.isSubset(of: actualKeys), actualKeys.isSubset(of: allowedKeys) else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    private func authenticatedData(for id: ZhulongSessionID, version: UInt8) -> Data {
        var data = Self.magic
        data.append(version)
        data.append(Data("noonmark.zhulong.session:\(id.description)".utf8))
        return data
    }

    private func legacyAuthenticatedData(for id: ZhulongSessionID) -> Data {
        Data("noonmark.zhulong.session:\(id.description)".utf8)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bitPattern = try container.decode(UInt64.self)
            return Date(
                timeIntervalSinceReferenceDate: Double(bitPattern: bitPattern)
            )
        }
        return decoder
    }
}
