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
        try saveRecord(ZhulongSessionRecord(session))
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
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(for: id)
            )
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let record = try decoder.decode(ZhulongSessionRecord.self, from: plaintext)
        return try record.restore(expectedID: id)
    }

    func saveRecordForTesting(_ record: ZhulongSessionRecord) throws {
        try saveRecord(record)
    }

    private func saveRecord(_ record: ZhulongSessionRecord) throws {
        let key = try symmetricKey()
        let plaintext = try encoder.encode(record)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData(for: record.id)
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
        let fileURL = fileURL(for: record.id)
        try envelope.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func decodeEnvelope(_ envelope: Data) throws -> Data {
        let headerSize = Self.magic.count + 1
        guard envelope.count > headerSize,
              envelope.prefix(Self.magic.count) == Self.magic,
              envelope[Self.magic.count] == Self.formatVersion
        else {
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

    private func authenticatedData(for id: ZhulongSessionID) -> Data {
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
