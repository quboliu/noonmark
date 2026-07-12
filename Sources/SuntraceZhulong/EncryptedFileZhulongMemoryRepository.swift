import CryptoKit
import Foundation

public protocol ZhulongMemoryRepository: Sendable {
    func save(_ ledger: ZhulongMemoryLedger) throws
    func load() throws -> ZhulongMemoryLedger
}

public struct EncryptedFileZhulongMemoryRepository: ZhulongMemoryRepository, @unchecked Sendable {
    private static let magic = Data("NOONMARK-ZHULONG-MEMORY".utf8)
    private static let formatVersion: UInt8 = 1
    private static let fileName = "memory.zhm"

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

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func save(_ ledger: ZhulongMemoryLedger) throws {
        try ledger.validateForPersistence()
        let key = try symmetricKey()
        let plaintext = try encoder.encode(ledger)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData
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
        try envelope.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func load() throws -> ZhulongMemoryLedger {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ZhulongSidecarRepositoryError.missingMemoryLedger
        }
        let envelope = try Data(contentsOf: fileURL)
        let headerSize = Self.magic.count + 1
        guard envelope.count > headerSize,
              envelope.prefix(Self.magic.count) == Self.magic,
              envelope[Self.magic.count] == Self.formatVersion
        else {
            throw ZhulongSidecarRepositoryError.unsupportedEnvelope
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: envelope.dropFirst(headerSize))
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealedBox,
                using: symmetricKey(),
                authenticating: authenticatedData
            )
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        do {
            let ledger = try decoder.decode(ZhulongMemoryLedger.self, from: plaintext)
            try ledger.validateForPersistence()
            return ledger
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    private func symmetricKey() throws -> SymmetricKey {
        let keyData = try keySource.loadOrCreateKey()
        guard keyData.count == 32 else {
            throw ZhulongSidecarRepositoryError.invalidKeyLength
        }
        return SymmetricKey(data: keyData)
    }

    private var authenticatedData: Data {
        var data = Self.magic
        data.append(Self.formatVersion)
        data.append(Data("noonmark.zhulong.memory".utf8))
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
            return Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern))
        }
        return decoder
    }
}
