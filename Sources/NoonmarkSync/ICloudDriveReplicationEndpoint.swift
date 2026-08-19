import Darwin
import Foundation

public enum ICloudAppendOnlyNamespaceError: Error, Equatable, Sendable {
    case pathAlreadyExists
    case invalidBoundary
    case cannotCreate
}

public struct ICloudAppendOnlyTestSession: Sendable {
    public let sessionID: UUID
    public let rootURL: URL
}

public struct ICloudAppendOnlyTestRound: Sendable {
    public let sessionID: UUID
    public let roundID: UUID
    public let rootURL: URL
}

public enum ICloudAppendOnlyTestNamespace {
    public static let relativeRoot =
        "Noonmark-E2E/AppendOnlyLiveTests"

    public static func beginSession(
        sessionID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> ICloudAppendOnlyTestSession {
        let root = try ICloudDriveRepositoryLocator.defaultRootURL(
            repositoryName: relativeRoot,
            fileManager: fileManager
        )
        return try beginSession(
            cloudDocumentsRoot: root.deletingLastPathComponent()
                .deletingLastPathComponent(),
            sessionID: sessionID,
            fileManager: fileManager
        )
    }

    static func beginSession(
        cloudDocumentsRoot: URL,
        sessionID: UUID,
        fileManager: FileManager = .default
    ) throws -> ICloudAppendOnlyTestSession {
        let cloudRoot = cloudDocumentsRoot.standardizedFileURL
        try validateExistingDirectory(cloudRoot, fileManager: fileManager)
        let noonmarkE2E = cloudRoot
            .appendingPathComponent("Noonmark-E2E", isDirectory: true)
        try ensureDirectory(noonmarkE2E, fileManager: fileManager)
        let base = noonmarkE2E
            .appendingPathComponent("AppendOnlyLiveTests", isDirectory: true)
            .standardizedFileURL
        try validateDescendant(base, of: cloudRoot)
        try ensureDirectory(base, fileManager: fileManager)
        let sessionURL = base.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        try createExclusiveDirectory(sessionURL)
        return ICloudAppendOnlyTestSession(
            sessionID: sessionID,
            rootURL: sessionURL
        )
    }

    public static func createRound(
        in session: ICloudAppendOnlyTestSession,
        roundID: UUID = UUID()
    ) throws -> ICloudAppendOnlyTestRound {
        try validateExistingDirectory(
            session.rootURL,
            fileManager: .default
        )
        let roundURL = session.rootURL.appendingPathComponent(
            roundID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        try validateDescendant(roundURL, of: session.rootURL)
        try createExclusiveDirectory(roundURL)
        return ICloudAppendOnlyTestRound(
            sessionID: session.sessionID,
            roundID: roundID,
            rootURL: roundURL
        )
    }

    public static func reopenRound(
        sessionID: UUID,
        roundID: UUID,
        fileManager: FileManager = .default
    ) throws -> ICloudAppendOnlyTestRound {
        let base = try ICloudDriveRepositoryLocator.defaultRootURL(
            repositoryName: relativeRoot,
            fileManager: fileManager
        )
        return try reopenRound(
            cloudDocumentsRoot: base.deletingLastPathComponent()
                .deletingLastPathComponent(),
            sessionID: sessionID,
            roundID: roundID,
            fileManager: fileManager
        )
    }

    static func reopenRound(
        cloudDocumentsRoot: URL,
        sessionID: UUID,
        roundID: UUID,
        fileManager: FileManager = .default
    ) throws -> ICloudAppendOnlyTestRound {
        let cloudRoot = cloudDocumentsRoot.standardizedFileURL
        try validateExistingDirectory(cloudRoot, fileManager: fileManager)
        let base = cloudRoot
            .appendingPathComponent("Noonmark-E2E", isDirectory: true)
            .appendingPathComponent("AppendOnlyLiveTests", isDirectory: true)
            .standardizedFileURL
        try validateDescendant(base, of: cloudRoot)
        try validateExistingDirectory(base, fileManager: fileManager)
        let sessionURL = base.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        try validateDescendant(sessionURL, of: base)
        try validateExistingDirectory(sessionURL, fileManager: fileManager)
        let roundURL = sessionURL.appendingPathComponent(
            roundID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        try validateDescendant(roundURL, of: sessionURL)
        try validateExistingDirectory(roundURL, fileManager: fileManager)
        return ICloudAppendOnlyTestRound(
            sessionID: sessionID,
            roundID: roundID,
            rootURL: roundURL
        )
    }
}

public struct ICloudReplicationObjectEvidence: Equatable, Sendable {
    public let exactURLObserved: Bool
    public let exactDigestMatches: Bool?
    public let isUbiquitous: Bool?
    public let isExcludedFromSync: Bool?
    public let hasUnresolvedConflicts: Bool?
    public let isUploading: Bool?
    public let isUploaded: Bool?
    public let uploadErrorCode: Int?

    public init(
        exactURLObserved: Bool,
        exactDigestMatches: Bool?,
        isUbiquitous: Bool?,
        isExcludedFromSync: Bool?,
        hasUnresolvedConflicts: Bool?,
        isUploading: Bool?,
        isUploaded: Bool?,
        uploadErrorCode: Int?
    ) {
        self.exactURLObserved = exactURLObserved
        self.exactDigestMatches = exactDigestMatches
        self.isUbiquitous = isUbiquitous
        self.isExcludedFromSync = isExcludedFromSync
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.uploadErrorCode = uploadErrorCode
    }
}

public enum ICloudReplicationEvidenceClassifier {
    public static func classify(
        _ evidence: ICloudReplicationObjectEvidence
    ) -> ReplicationPublicationObservationState {
        guard evidence.exactURLObserved else { return .awaiting }
        guard let exactDigestMatches = evidence.exactDigestMatches else {
            return .awaiting
        }
        guard exactDigestMatches else {
            return .blockedCorruption
        }
        if let uploadErrorCode = evidence.uploadErrorCode {
            return uploadErrorCode == 4354
                ? .blockedUserAttention
                : .awaiting
        }
        if evidence.isExcludedFromSync == true {
            return .blockedUserAttention
        }
        if evidence.hasUnresolvedConflicts == true {
            return .blockedCorruption
        }
        guard evidence.isUbiquitous == true,
              evidence.isExcludedFromSync != nil,
              evidence.hasUnresolvedConflicts == false,
              evidence.isUploading == false,
              evidence.isUploaded == true
        else { return .awaiting }
        return .confirmed
    }

    public static func aggregate(
        _ states: [ReplicationPublicationObservationState]
    ) -> ReplicationPublicationObservationState {
        guard states.isEmpty == false else { return .awaiting }
        if states.contains(.blockedCorruption) {
            return .blockedCorruption
        }
        if states.contains(.blockedUserAttention) {
            return .blockedUserAttention
        }
        return states.allSatisfy { $0 == .confirmed }
            ? .confirmed
            : .awaiting
    }
}

public enum ICloudDriveReplicationEndpointError:
    Error,
    Equatable,
    Sendable
{
    case invalidRoundBoundary
    case downloadIncomplete
}

public actor ICloudDriveReplicationEndpoint: ReplicationEndpoint {
    private struct Boundary: Sendable {
        let rootURL: URL
        let requiredSuffix: String?
    }

    public nonisolated let namespace: String
    public nonisolated let rootURL: URL
    public nonisolated let round: ICloudAppendOnlyTestRound?
    public nonisolated let generationID: UUID
    public nonisolated let repositoryWasCreated: Bool

    private let boundary: Boundary
    private let files: ContentAddressedFileReplicationEndpoint
    private let downloadRequest: (URL) throws -> Void
    private let repositoryAuthorityDescriptor:
        ReplicationRepositoryDescriptor?
    private let repositoryAuthorityValidation: @Sendable () async throws
        -> Void
    private let repositoryAuthorityPostValidation: @Sendable () async throws
        -> Void

    public init(
        round: ICloudAppendOnlyTestRound,
        existingGenerationID: UUID? = nil
    ) throws {
        let repositoryScope = ICloudAppendOnlyTestNamespace.relativeRoot
            + "/" + round.sessionID.uuidString.lowercased()
            + "/" + round.roundID.uuidString.lowercased()
        let result = try ICloudReplicationRepositoryAuthority.openRepository(
            at: round.rootURL,
            scope: repositoryScope,
            existingGenerationID: existingGenerationID
        )
        self.round = round
        rootURL = round.rootURL
        self.generationID = result.descriptor.generationID
        repositoryWasCreated = result.createdRepository
        boundary = Boundary(
            rootURL: round.rootURL,
            requiredSuffix:
            "/\(round.sessionID.uuidString.lowercased())/\(round.roundID.uuidString.lowercased())"
        )
        files = ContentAddressedFileReplicationEndpoint(
            rootURL: round.rootURL,
            generationID: result.descriptor.generationID,
            fileReadPolicy: .coordinated,
            repositoryWasCreated: result.createdRepository
        )
        downloadRequest = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
        repositoryAuthorityDescriptor = result.descriptor
        repositoryAuthorityValidation = {}
        repositoryAuthorityPostValidation = {}
        namespace = "icloud-append-only-" + round.sessionID.uuidString
            .lowercased() + "-" + round.roundID.uuidString.lowercased()
    }

    public init(
        repositoryName: String,
        existingGenerationID: UUID? = nil
    ) throws {
        let resolvedRoot = try ICloudDriveRepositoryLocator.defaultRootURL(
            repositoryName: repositoryName
        )
        let result = try ICloudReplicationRepositoryAuthority.openRepository(
            at: resolvedRoot,
            scope: repositoryName,
            existingGenerationID: existingGenerationID
        )
        round = nil
        rootURL = resolvedRoot
        self.generationID = result.descriptor.generationID
        repositoryWasCreated = result.createdRepository
        boundary = Boundary(rootURL: resolvedRoot, requiredSuffix: nil)
        files = ContentAddressedFileReplicationEndpoint(
            rootURL: resolvedRoot,
            generationID: result.descriptor.generationID,
            fileReadPolicy: .coordinated,
            repositoryWasCreated: result.createdRepository
        )
        downloadRequest = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
        repositoryAuthorityDescriptor = result.descriptor
        repositoryAuthorityValidation = {}
        repositoryAuthorityPostValidation = {}
        namespace = "icloud-" + files.namespace
    }

    init(
        rootURL: URL,
        generationID: UUID,
        fileReadPolicy: ReplicationFileReadPolicy = .direct,
        fileDataReader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0)
        },
        repositoryAuthorityValidation: @escaping @Sendable () async throws
            -> Void = {},
        repositoryAuthorityPostValidation: @escaping @Sendable () async throws
            -> Void = {},
        downloadRequest: @escaping (URL) throws -> Void
    ) {
        round = nil
        self.rootURL = rootURL
        self.generationID = generationID
        repositoryWasCreated = false
        boundary = Boundary(rootURL: rootURL, requiredSuffix: nil)
        files = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID,
            fileReadPolicy: fileReadPolicy,
            fileDataReader: fileDataReader
        )
        self.downloadRequest = downloadRequest
        repositoryAuthorityDescriptor = nil
        self.repositoryAuthorityValidation = repositoryAuthorityValidation
        self.repositoryAuthorityPostValidation =
            repositoryAuthorityPostValidation
        namespace = "icloud-" + files.namespace
    }

    public func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        try validateBoundary()
        return try await withRepositoryAuthority {
            try await files.publish(sealed: publication)
        }
    }

    public func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        guard receipts.isEmpty == false else { return [] }
        try validateBoundary()
        return try await withRepositoryAuthority {
            try receipts.map { receipt in
                let states = try receipt.objects.map { object in
                    ICloudReplicationEvidenceClassifier.classify(
                        try evidence(for: object)
                    )
                }
                return ReplicationPublicationObservation(
                    reference: receipt.reference,
                    state: ICloudReplicationEvidenceClassifier.aggregate(
                        states
                    )
                )
            }
        }
    }

    public func read(
        after cursor: ReplicationReadCursor,
        budget: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        try validateBoundary()
        return try await withRepositoryAuthority {
            var isAwaitingMaterialization = false
            for url in try regularJSONFilesInBoundary() {
                if try requestDownloadIfNeeded(at: url) == false {
                    isAwaitingMaterialization = true
                }
            }
            if isAwaitingMaterialization {
                return ReplicationReadPage(
                    publications: [],
                    cursor: cursor,
                    hasMore: false,
                    openedByteCount: 0,
                    state: .awaitingMaterialization
                )
            }
            do {
                return try await files.read(after: cursor, budget: budget)
            } catch let error as FileReplicationEndpointError {
                let missingURL: URL
                switch error {
                case let .announcementGap(
                    producerID,
                    missingSequence,
                    highestObservedSequence
                ):
                    guard missingSequence > 0,
                          missingSequence <= highestObservedSequence
                    else {
                        throw error
                    }
                    missingURL = rootURL.appendingPathComponent(
                        "v2/announcements/\(generationID.uuidString.lowercased())/\(producerID.uuidString.lowercased())/\(String(format: "%020llu", missingSequence))",
                        isDirectory: true
                    ).standardizedFileURL
                case let .objectNotMaterialized(relativeKey):
                    missingURL = try descendantURL(relativeKey: relativeKey)
                default:
                    throw error
                }
                try validateDescendant(missingURL)
                try downloadRequest(missingURL)
                return ReplicationReadPage(
                    publications: [],
                    cursor: cursor,
                    hasMore: true,
                    openedByteCount: 0,
                    state: .awaitingMaterialization
                )
            }
        }
    }

    public func cancelAndJoin() async {
        await files.cancelAndJoin()
    }
}

private extension ICloudDriveReplicationEndpoint {
    func withRepositoryAuthority<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        if let repositoryAuthorityDescriptor {
            let lease = try await ICloudReplicationRepositoryAuthority
                .beginValidatedMarkerAuthority(
                    at: rootURL.appendingPathComponent(
                        FileReplicationRepositoryBootstrap.markerFilename
                    ),
                    expected: repositoryAuthorityDescriptor
                )
            do {
                let result = try await operation()
                try await ICloudReplicationRepositoryAuthority
                    .finishValidatedMarkerAuthority(lease)
                return result
            } catch {
                ICloudReplicationRepositoryAuthority
                    .cancelValidatedMarkerAuthority(lease)
                throw error
            }
        }
        try await repositoryAuthorityValidation()
        let result = try await operation()
        try await repositoryAuthorityPostValidation()
        return result
    }

    func validateBoundary() throws {
        let expected = boundary.rootURL.standardizedFileURL.path
        guard expected != "/",
              expected == rootURL.standardizedFileURL.path,
              boundary.requiredSuffix.map({ expected.hasSuffix($0) }) ?? true
        else {
            throw ICloudDriveReplicationEndpointError.invalidRoundBoundary
        }
    }

    func validateDescendant(_ url: URL) throws {
        let root = rootURL.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root + "/") else {
            throw ICloudDriveReplicationEndpointError.invalidRoundBoundary
        }
    }

    func descendantURL(relativeKey: String) throws -> URL {
        guard relativeKey.isEmpty == false,
              relativeKey.hasPrefix("/") == false,
              relativeKey.split(separator: "/").allSatisfy({
                  $0 != "." && $0 != ".."
              })
        else {
            throw ICloudDriveReplicationEndpointError.invalidRoundBoundary
        }
        let url = rootURL.appendingPathComponent(
            relativeKey
        ).standardizedFileURL
        try validateDescendant(url)
        return url
    }

    func objectURL(
        for reference: ReplicationObjectReference
    ) throws -> URL {
        guard reference.relativeKey.isEmpty == false,
              reference.relativeKey.hasPrefix("/") == false,
              reference.relativeKey.split(separator: "/").allSatisfy({
                  $0 != "." && $0 != ".."
              })
        else {
            throw ICloudDriveReplicationEndpointError.invalidRoundBoundary
        }
        let url = rootURL.appendingPathComponent(
            reference.relativeKey
        ).standardizedFileURL
        try validateDescendant(url)
        return url
    }

    func evidence(
        for reference: ReplicationObjectReference
    ) throws -> ICloudReplicationObjectEvidence {
        let url = try objectURL(for: reference)
        guard fileManagerFileExists(at: url) else {
            return ICloudReplicationObjectEvidence(
                exactURLObserved: false,
                exactDigestMatches: nil,
                isUbiquitous: nil,
                isExcludedFromSync: nil,
                hasUnresolvedConflicts: nil,
                isUploading: nil,
                isUploaded: nil,
                uploadErrorCode: nil
            )
        }
        let exactDigestMatches: Bool?
        do {
            let data = try coordinatedData(at: url)
            let digest = try ReplicationPublicationBuilder.digest(data)
            exactDigestMatches = Int64(data.count) == reference.byteCount
                && digest == reference.digest
        } catch {
            exactDigestMatches = nil
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isUbiquitousItemKey,
                    .ubiquitousItemIsExcludedFromSyncKey,
                    .ubiquitousItemHasUnresolvedConflictsKey,
                    .ubiquitousItemIsUploadingKey,
                    .ubiquitousItemIsUploadedKey,
                    .ubiquitousItemUploadingErrorKey,
                ]
            )
        } catch {
            return ICloudReplicationObjectEvidence(
                exactURLObserved: true,
                exactDigestMatches: exactDigestMatches,
                isUbiquitous: nil,
                isExcludedFromSync: nil,
                hasUnresolvedConflicts: nil,
                isUploading: nil,
                isUploaded: nil,
                uploadErrorCode: nil
            )
        }
        return ICloudReplicationObjectEvidence(
            exactURLObserved: true,
            exactDigestMatches: exactDigestMatches,
            isUbiquitous: values.isUbiquitousItem,
            isExcludedFromSync: values.ubiquitousItemIsExcludedFromSync,
            hasUnresolvedConflicts:
                values.ubiquitousItemHasUnresolvedConflicts,
            isUploading: values.ubiquitousItemIsUploading,
            isUploaded: values.ubiquitousItemIsUploaded,
            uploadErrorCode: values.ubiquitousItemUploadingError.map {
                ($0 as NSError).code
            }
        )
    }

    func fileManagerFileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue == false
    }

    func regularJSONFilesInBoundary() throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            try validateDescendant(url)
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw ICloudDriveReplicationEndpointError
                    .invalidRoundBoundary
            }
            return values.isRegularFile == true
                    && url.pathExtension == "json"
                ? url
                : nil
        }
    }

    func requestDownloadIfNeeded(at url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey,
            ]
        )
        if values.ubiquitousItemDownloadingError != nil {
            throw ICloudDriveReplicationEndpointError.downloadIncomplete
        }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current
        {
            try downloadRequest(url)
            return false
        }
        return true
    }

    func coordinatedData(at url: URL) throws -> Data {
        var coordinatedData: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                coordinatedData = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let readError {
            throw readError
        }
        guard let coordinatedData else {
            throw ICloudDriveReplicationEndpointError.downloadIncomplete
        }
        return coordinatedData
    }
}

private extension ICloudAppendOnlyTestNamespace {
    static func validateDescendant(_ child: URL, of parent: URL) throws {
        let root = parent.standardizedFileURL.path
        let candidate = child.standardizedFileURL.path
        guard root != "/",
              candidate.hasPrefix(root + "/")
        else {
            throw ICloudAppendOnlyNamespaceError.invalidBoundary
        }
    }

    static func createExclusiveDirectory(_ url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkdir($0, S_IRWXU) } ?? -1
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw ICloudAppendOnlyNamespaceError.pathAlreadyExists
            }
            throw ICloudAppendOnlyNamespaceError.cannotCreate
        }
    }

    static func ensureDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        do {
            try createExclusiveDirectory(url)
        } catch ICloudAppendOnlyNamespaceError.pathAlreadyExists {
            try validateExistingDirectory(url, fileManager: fileManager)
        }
    }

    static func validateExistingDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ICloudAppendOnlyNamespaceError.invalidBoundary
        }
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw ICloudAppendOnlyNamespaceError.invalidBoundary
        }
    }
}
