import Foundation
import NoonmarkDiagnostics

public enum ICloudDriveSyncTransportError: Error, Equatable, Sendable {
    case unavailable
    case accountUnavailable
    case driveUnavailable
}

private struct ICloudDriveUploadObservation: Sendable {
    let isUploaded: Bool
    let hasUploadingError: Bool
}

extension ICloudDriveSyncTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "当前同步端点不可用。"
        case .accountUnavailable:
            "iCloud Drive 不可用：请先登录 Apple Account 并开启 iCloud Drive。"
        case .driveUnavailable:
            "找不到 iCloud Drive 本机目录，请在系统设置中确认 iCloud Drive 已启用。"
        }
    }
}

public actor ICloudDriveSyncTransport: SyncRecordTransport {
    public nonisolated static let defaultRepositoryName = "Noonmark/SyncRepository"

    private let localTransport: LocalFolderSyncTransport
    public let rootURL: URL
    public nonisolated let frontierNamespace: String

    public init(
        repositoryName: String,
        producerEpochID: UUID = UUID(),
        fileManager: FileManager = .default,
        diagnosticOperation: DiagnosticOperation? = nil
    ) throws {
        let rootURL = try Self.defaultRootURL(repositoryName: repositoryName, fileManager: fileManager)
        self.init(
            rootURL: rootURL,
            producerEpochID: producerEpochID,
            diagnosticOperation: diagnosticOperation
        )
    }

    public init(
        rootURL: URL,
        producerEpochID: UUID = UUID(),
        diagnosticOperation: DiagnosticOperation? = nil
    ) {
        self.rootURL = rootURL
        frontierNamespace = LocalFolderSyncTransport.frontierNamespace(
            for: rootURL
        )
        localTransport = LocalFolderSyncTransport(
            rootURL: rootURL,
            producerEpochID: producerEpochID,
            diagnosticOperation: diagnosticOperation
        )
    }

    public nonisolated static func defaultRootURL(
        repositoryName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let cloudDocsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return try resolvedRootURL(
            repositoryName: repositoryName,
            ubiquitousContainerURL: fileManager.url(forUbiquityContainerIdentifier: nil),
            cloudDocsURL: cloudDocsURL,
            hasICloudAccount: fileManager.ubiquityIdentityToken != nil,
            cloudDocsExists: fileManager.fileExists(atPath: cloudDocsURL.path)
        )
    }

    nonisolated static func resolvedRootURL(
        repositoryName: String,
        ubiquitousContainerURL: URL?,
        cloudDocsURL: URL,
        hasICloudAccount: Bool,
        cloudDocsExists: Bool
    ) throws -> URL {
        guard hasICloudAccount else {
            throw ICloudDriveSyncTransportError.accountUnavailable
        }
        if let ubiquitousContainerURL {
            return ubiquitousContainerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(repositoryName, isDirectory: true)
        }
        guard cloudDocsExists else {
            throw ICloudDriveSyncTransportError.driveUnavailable
        }
        return cloudDocsURL.appendingPathComponent(repositoryName, isDirectory: true)
    }

    public func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        let receipt = try await localTransport.pushAccepting(records)
        guard receipt.batches.isEmpty == false else { return receipt }
        return receipt.replacingConfirmation(
            .awaitingUploadConfirmation
        )
    }

    public func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        try await localTransport.pull(after: frontier, limit: limit)
    }

    public func confirmationStatus(
        for receipt: SyncTransportPushReceipt
    ) async throws -> SyncTransportConfirmation {
        guard receipt.confirmation != .confirmed,
              receipt.batches.isEmpty == false
        else { return .confirmed }
        var awaiting = false
        for batch in receipt.batches {
            for relativePath in batch.artifactPaths {
                let url = try artifactURL(relativePath: relativePath)
                let observation = try uploadObservation(for: url)
                if observation.hasUploadingError {
                    return .blockedUserAttention
                }
                if observation.isUploaded == false {
                    awaiting = true
                }
            }
        }
        return awaiting ? .awaitingUploadConfirmation : .confirmed
    }

    public func fetchSnapshots() async throws -> [SyncRepositorySnapshot] {
        try await localTransport.fetchSnapshots()
    }

    private func artifactURL(relativePath: String) throws -> URL {
        guard relativePath.isEmpty == false,
              relativePath.hasPrefix("/") == false,
              relativePath.split(separator: "/").allSatisfy({
                  $0 != "." && $0 != ".."
              })
        else {
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
        let root = rootURL.standardizedFileURL
        let resolved = root.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
        return resolved
    }

    private func uploadObservation(
        for url: URL
    ) throws -> ICloudDriveUploadObservation {
        let values = try url.resourceValues(
            forKeys: [
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemUploadingErrorKey
            ]
        )
        return ICloudDriveUploadObservation(
            isUploaded: values.ubiquitousItemIsUploaded ?? false,
            hasUploadingError: values.ubiquitousItemUploadingError != nil
        )
    }
}
