import CryptoKit
import Foundation
import NoonmarkCore

public enum ZhulongPendingApplicationKind: Codable, Equatable, Sendable {
    case todoDiff(ZhulongTodoDiffID)
    case dailyReview(ZhulongDailyReviewDraftID)
}

public struct ZhulongPendingApplication: Equatable, Sendable {
    public let id: UUID
    public let kind: ZhulongPendingApplicationKind
    public let sessionID: ZhulongSessionID
    public let beforeSnapshot: NoonmarkSnapshot
    public let afterSnapshot: NoonmarkSnapshot
    public let afterSession: ZhulongSession
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: ZhulongPendingApplicationKind,
        sessionID: ZhulongSessionID,
        beforeSnapshot: NoonmarkSnapshot,
        afterSnapshot: NoonmarkSnapshot,
        afterSession: ZhulongSession,
        createdAt: Date = Date()
    ) throws {
        guard afterSession.id == sessionID,
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        try beforeSnapshot.validateIntegrity()
        try afterSnapshot.validateIntegrity()
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.beforeSnapshot = beforeSnapshot
        self.afterSnapshot = afterSnapshot
        self.afterSession = afterSession
        self.createdAt = createdAt
    }
}

public struct EncryptedFileZhulongApplicationJournal: @unchecked Sendable {
    private static let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
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

    public var fileURL: URL {
        directoryURL.appendingPathComponent("pending-application.zhj", isDirectory: false)
    }

    public func save(_ application: ZhulongPendingApplication) throws {
        let record = ZhulongPendingApplicationRecord(application)
        _ = try record.restore()
        let plaintext = try encoder.encode(record)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: try symmetricKey(),
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
        try envelope.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func load() throws -> ZhulongPendingApplication? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
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
                using: try symmetricKey(),
                authenticating: authenticatedData
            )
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
        do {
            return try decoder.decode(ZhulongPendingApplicationRecord.self, from: plaintext).restore()
        } catch let error as ZhulongSidecarRepositoryError {
            throw error
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private var authenticatedData: Data {
        var data = Self.magic
        data.append(Self.formatVersion)
        return data
    }

    private func symmetricKey() throws -> SymmetricKey {
        let key = try keySource.loadOrCreateKey()
        guard key.count == 32 else {
            throw ZhulongSidecarRepositoryError.invalidKeyLength
        }
        return SymmetricKey(data: key)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct ZhulongPendingApplicationRecord: Codable {
    let id: UUID
    let kind: ZhulongPendingApplicationKind
    let sessionID: ZhulongSessionID
    let beforeSnapshot: NoonmarkSnapshot
    let afterSnapshot: NoonmarkSnapshot
    let afterSession: ZhulongSessionRecord
    let createdAt: Date

    init(_ application: ZhulongPendingApplication) {
        id = application.id
        kind = application.kind
        sessionID = application.sessionID
        beforeSnapshot = application.beforeSnapshot
        afterSnapshot = application.afterSnapshot
        afterSession = ZhulongSessionRecord(application.afterSession)
        createdAt = application.createdAt
    }

    func restore() throws -> ZhulongPendingApplication {
        let session = try afterSession.restore(expectedID: sessionID)
        return try ZhulongPendingApplication(
            id: id,
            kind: kind,
            sessionID: sessionID,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            afterSession: session,
            createdAt: createdAt
        )
    }
}
