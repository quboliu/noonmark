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
    case missingMemoryLedger
}

public struct EncryptedFileZhulongSessionRepository: ZhulongSessionRepository, @unchecked Sendable {
    private static let magic = Data("NOONMARK-ZHULONG-SIDECAR".utf8)
    private static let formatVersion: UInt8 = 1

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
        let record = ZhulongSessionRecord(session)
        _ = try record.restore(expectedID: session.id)
        try saveRecord(record)
    }

    public func load(_ id: ZhulongSessionID) throws -> ZhulongSession {
        let fileURL = fileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ZhulongSidecarRepositoryError.missingSession
        }
        let envelope = try Data(contentsOf: fileURL)
        let ciphertext = try decodeEnvelope(envelope)
        let key = try symmetricKey()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let plaintext = try decrypt(
            sealedBox,
            using: key,
            id: id
        )
        try validateSchema(plaintext)
        let record = try decoder.decode(ZhulongSessionRecord.self, from: plaintext)
        return try record.restore(expectedID: id)
    }

    func saveRecordForTesting(_ record: ZhulongSessionRecord) throws {
        try saveRecord(record)
    }

    func saveCurrentSessionWithoutPurposeForTesting(_ session: ZhulongSession) throws {
        try saveCurrentSessionForTesting(session, removingField: "purpose")
    }

    func saveCurrentSessionWithoutDailyLedgerForTesting(_ session: ZhulongSession) throws {
        try saveCurrentSessionForTesting(session, removingField: "dailyCloseSnapshots")
    }

    private func saveCurrentSessionForTesting(
        _ session: ZhulongSession,
        removingField field: String
    ) throws {
        let data = try encoder.encode(ZhulongSessionRecord(session))
        let object = try JSONSerialization.jsonObject(with: data)
        guard var dictionary = object as? [String: Any] else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        dictionary.removeValue(forKey: field)
        try savePlaintext(
            JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
            id: session.id
        )
    }

    private func saveRecord(_ record: ZhulongSessionRecord) throws {
        try savePlaintext(encoder.encode(record), id: record.id)
    }

    private func savePlaintext(
        _ plaintext: Data,
        id: ZhulongSessionID
    ) throws {
        let key = try symmetricKey()
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData(for: id)
        )
        guard let combined = sealedBox.combined else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }

        var envelope = Self.magic
        envelope.append(Self.formatVersion)
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

    private func decodeEnvelope(_ envelope: Data) throws -> Data {
        let headerSize = Self.magic.count + 1
        guard envelope.count > headerSize,
              envelope.prefix(Self.magic.count) == Self.magic
        else {
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        let version = envelope[Self.magic.count]
        guard version == Self.formatVersion else {
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        return envelope.dropFirst(headerSize)
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
        id: ZhulongSessionID
    ) throws -> Data {
        do {
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(for: id)
            )
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    private func validateSchema(_ plaintext: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext),
              let record = object as? [String: Any]
        else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let actualKeys = Set(record.keys)
        guard ZhulongSessionRecord.requiredPersistenceKeys.isSubset(of: actualKeys),
              actualKeys.isSubset(of: ZhulongSessionRecord.allowedPersistenceKeys)
        else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    private func authenticatedData(for id: ZhulongSessionID) -> Data {
        var data = Self.magic
        data.append(Self.formatVersion)
        data.append(Data("noonmark.zhulong.session:\(id.description)".utf8))
        return data
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
