import Foundation

public enum ICloudDriveSyncTransportError: Error, Equatable, Sendable {
    case unavailable
}

public actor ICloudDriveSyncTransport: SyncRecordTransport {
    public nonisolated static let defaultRepositoryName = "Noonmark/SyncRepository"

    private let localTransport: LocalFolderSyncTransport
    public let rootURL: URL

    public init(
        repositoryName: String = ICloudDriveSyncTransport.defaultRepositoryName,
        fileManager: FileManager = .default
    ) throws {
        let rootURL = try Self.defaultRootURL(repositoryName: repositoryName, fileManager: fileManager)
        self.init(rootURL: rootURL)
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL
        localTransport = LocalFolderSyncTransport(rootURL: rootURL)
    }

    public nonisolated static func defaultRootURL(
        repositoryName: String = ICloudDriveSyncTransport.defaultRepositoryName,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let ubiquitousURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            return ubiquitousURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(repositoryName, isDirectory: true)
        }

        let cloudDocsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard fileManager.fileExists(atPath: cloudDocsURL.path) else {
            throw ICloudDriveSyncTransportError.unavailable
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
