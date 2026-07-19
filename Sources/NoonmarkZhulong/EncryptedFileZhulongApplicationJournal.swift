import CryptoKit
import Foundation
import NoonmarkCore

public enum ZhulongPendingApplicationKind: Codable, Equatable, Sendable {
    case todoDiff(ZhulongTodoDiffID)
    case dailyReview(ZhulongDailyReviewDraftID)
}

public enum ZhulongJournalClearRequirement: Equatable, Sendable {
    case beforeSession
    case afterSession
}

public struct ZhulongPendingApplication: Equatable, Sendable {
    public let id: UUID
    public let kind: ZhulongPendingApplicationKind
    public let sessionID: ZhulongSessionID
    public let beforeSnapshot: NoonmarkSnapshot
    public let afterSnapshot: NoonmarkSnapshot
    public let beforeSession: ZhulongSession
    public let afterSession: ZhulongSession
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: ZhulongPendingApplicationKind,
        sessionID: ZhulongSessionID,
        beforeSnapshot: NoonmarkSnapshot,
        afterSnapshot: NoonmarkSnapshot,
        beforeSession: ZhulongSession,
        afterSession: ZhulongSession,
        createdAt: Date
    ) throws {
        guard beforeSession.id == sessionID,
              afterSession.id == sessionID,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              beforeSession.latestActivityAt < createdAt,
              afterSession.latestActivityAt == createdAt
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
        self.beforeSession = beforeSession
        self.afterSession = afterSession
        self.createdAt = createdAt
    }
}

public struct EncryptedFileZhulongApplicationJournal: @unchecked Sendable {
    private static let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
    private static let formatVersion: UInt8 = 3
    private static let currentPlaintextKeys: Set<String> = [
        "afterSession",
        "afterSnapshot",
        "beforeSession",
        "beforeSnapshot",
        "createdAt",
        "id",
        "kind",
        "sessionID"
    ]

    public let directoryURL: URL
    private let keySource: any ZhulongSidecarKeySource
    private let fileManager: FileManager
    private let fileCommitter: ZhulongApplicationJournalFileCommitter

    public init(
        directoryURL: URL,
        keySource: any ZhulongSidecarKeySource,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.keySource = keySource
        self.fileManager = fileManager
        fileCommitter = ZhulongApplicationJournalFileCommitter()
    }

    init(
        directoryURL: URL,
        keySource: any ZhulongSidecarKeySource,
        fileManager: FileManager = .default,
        fileOperations: ZhulongJournalDarwinOperations,
        monitor: @escaping ZhulongApplicationJournalMonitor = { _ in }
    ) {
        self.directoryURL = directoryURL
        self.keySource = keySource
        self.fileManager = fileManager
        fileCommitter = ZhulongApplicationJournalFileCommitter(
            operations: fileOperations,
            monitor: monitor
        )
    }

    public var fileURL: URL {
        transactionLock.pendingApplicationURL
    }

    @discardableResult
    public func save(
        _ application: ZhulongPendingApplication
    ) throws -> ZhulongApplicationJournalCommitOutcome {
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
        return try transactionLock.withExclusiveLock {
            try transactionLock.assertNoPendingApplicationUnlocked()
            let persistedSession = try sessionRepository.loadUnlocked(
                application.sessionID
            )
            guard persistedSession == application.beforeSession else {
                throw ZhulongSidecarRepositoryError.sessionConflict
            }
            do {
                return try fileCommitter.install(
                    exactBytes: envelope,
                    at: fileURL,
                    authenticate: { candidate in
                        try decodeApplication(from: candidate) == application
                    }
                )
            } catch let failure as ZhulongApplicationJournalMutationFailure {
                if failure.disposition == .unresolved {
                    transactionLock.markApplicationCommitUnresolved(
                        operation: failure.operation,
                        exactBytes: envelope
                    )
                }
                throw failure
            }
        }
    }

    public func load() throws -> ZhulongPendingApplication? {
        try transactionLock.withExclusiveLock {
            try loadUnlocked()
        }
    }

    func loadUnlocked() throws -> ZhulongPendingApplication? {
        try fileCommitter.cleanupOrphanedTemporaryFiles(for: fileURL)
        if let fence = try transactionLock.unresolvedApplicationCommit() {
            let expectedApplication = try decodeApplication(
                from: fence.exactBytes
            )
            let isPresent = try fileCommitter.resolveUncertainMutation(
                operation: fence.operation,
                exactBytes: fence.exactBytes,
                at: fileURL,
                authenticate: { candidate in
                    try decodeApplication(from: candidate)
                        == expectedApplication
                }
            )
            try transactionLock.clearApplicationCommitFence()
            guard isPresent else { return nil }
            return expectedApplication
        }
        guard let envelope = try fileCommitter.read(at: fileURL) else {
            return nil
        }
        return try decodeApplication(from: envelope)
    }

    private func decodeApplication(
        from envelope: Data
    ) throws -> ZhulongPendingApplication {
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
            try validateCurrentPlaintextSchema(plaintext)
            return try decoder
                .decode(
                    ZhulongPendingApplicationRecord.self,
                    from: plaintext
                )
                .restore()
        } catch let error as ZhulongSidecarRepositoryError {
            throw error
        } catch {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    private func validateCurrentPlaintextSchema(_ plaintext: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext),
              let application = object as? [String: Any],
              Set(application.keys) == Self.currentPlaintextKeys
        else {
            throw ZhulongSidecarRepositoryError.invalidCiphertext
        }
    }

    @discardableResult
    public func clear(
        _ expectedApplication: ZhulongPendingApplication,
        requiring requirement: ZhulongJournalClearRequirement
    ) throws -> ZhulongApplicationJournalCommitOutcome {
        try transactionLock.withExclusiveLock {
            guard let exactEnvelope = try fileCommitter.read(at: fileURL),
                  try decodeApplication(from: exactEnvelope)
                  == expectedApplication
            else {
                throw ZhulongSidecarRepositoryError
                    .pendingApplicationConflict
            }
            let requiredSession = switch requirement {
            case .beforeSession:
                expectedApplication.beforeSession
            case .afterSession:
                expectedApplication.afterSession
            }
            let persistedSession = try sessionRepository.loadUnlocked(
                expectedApplication.sessionID
            )
            guard persistedSession == requiredSession else {
                throw ZhulongSidecarRepositoryError.sessionConflict
            }
            do {
                let outcome = try fileCommitter.remove(
                    exactBytes: exactEnvelope,
                    at: fileURL,
                    authenticate: { candidate in
                        try decodeApplication(from: candidate)
                            == expectedApplication
                    }
                )
                try transactionLock.clearApplicationCommitFence()
                return outcome
            } catch let failure as ZhulongApplicationJournalMutationFailure {
                if failure.disposition == .unresolved {
                    transactionLock.markApplicationCommitUnresolved(
                        operation: failure.operation,
                        exactBytes: exactEnvelope
                    )
                }
                throw failure
            }
        }
    }

    private var transactionLock: ZhulongSidecarTransactionLock {
        ZhulongSidecarTransactionLock(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
    }

    private var sessionRepository: EncryptedFileZhulongSessionRepository {
        EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: keySource,
            fileManager: fileManager
        )
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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw ZhulongSidecarRepositoryError.invalidCiphertext
            }
            var container = encoder.singleValueContainer()
            try container.encode(seconds.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bitPattern = try container.decode(UInt64.self)
            let seconds = Double(bitPattern: bitPattern)
            guard seconds.isFinite else {
                throw ZhulongSidecarRepositoryError.invalidCiphertext
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }
}

private struct ZhulongPendingApplicationRecord: Codable {
    let id: UUID
    let kind: ZhulongPendingApplicationKind
    let sessionID: ZhulongSessionID
    let beforeSnapshot: NoonmarkSnapshot
    let afterSnapshot: NoonmarkSnapshot
    let beforeSession: ZhulongSessionRecord
    let afterSession: ZhulongSessionRecord
    let createdAt: Date

    init(_ application: ZhulongPendingApplication) {
        id = application.id
        kind = application.kind
        sessionID = application.sessionID
        beforeSnapshot = application.beforeSnapshot
        afterSnapshot = application.afterSnapshot
        beforeSession = ZhulongSessionRecord(application.beforeSession)
        afterSession = ZhulongSessionRecord(application.afterSession)
        createdAt = application.createdAt
    }

    func restore() throws -> ZhulongPendingApplication {
        let before = try beforeSession.restore(expectedID: sessionID)
        let after = try afterSession.restore(expectedID: sessionID)
        return try ZhulongPendingApplication(
            id: id,
            kind: kind,
            sessionID: sessionID,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            beforeSession: before,
            afterSession: after,
            createdAt: createdAt
        )
    }
}
