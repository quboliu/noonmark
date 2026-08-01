import Foundation
import NoonmarkDiagnostics

public enum ICloudDriveSyncTransportError: Error, Equatable, Sendable {
    case unavailable
    case accountUnavailable
    case driveUnavailable
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

    public init(
        repositoryName: String,
        fileManager: FileManager = .default,
        diagnosticOperation: DiagnosticOperation? = nil
    ) throws {
        let rootURL = try Self.defaultRootURL(repositoryName: repositoryName, fileManager: fileManager)
        self.init(
            rootURL: rootURL,
            diagnosticOperation: diagnosticOperation
        )
    }

    public init(
        rootURL: URL,
        diagnosticOperation: DiagnosticOperation? = nil
    ) {
        self.rootURL = rootURL
        localTransport = LocalFolderSyncTransport(
            rootURL: rootURL,
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

    public func push(_ records: [SyncRecord]) async throws {
        try await localTransport.push(records)
    }

    public func fetchAll() async throws -> [SyncRecord] {
        try await localTransport.fetchAll()
    }

    public func fetchSnapshots() async throws -> [SyncRepositorySnapshot] {
        try await localTransport.fetchSnapshots()
    }
}
