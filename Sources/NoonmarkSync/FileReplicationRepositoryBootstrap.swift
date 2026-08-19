import Darwin
import Foundation

public enum ReplicationRepositoryBootstrapError:
    Error,
    Equatable,
    Sendable
{
    case legacyRepositoryRequiresManualReset
    case invalidBoundary
    case invalidMarker
    case cannotCreateMarker
    case markerPublicationInProgress
    case markerUnavailableForExistingAuthority
}

public struct ReplicationRepositoryDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let formatVersion: Int
    public let generationID: UUID

    public init(formatVersion: Int, generationID: UUID) {
        self.formatVersion = formatVersion
        self.generationID = generationID
    }
}

public struct ReplicationRepositoryOpenResult: Equatable, Sendable {
    public let descriptor: ReplicationRepositoryDescriptor
    public let createdRepository: Bool

    public init(
        descriptor: ReplicationRepositoryDescriptor,
        createdRepository: Bool
    ) {
        self.descriptor = descriptor
        self.createdRepository = createdRepository
    }
}

public enum FileReplicationRepositoryBootstrap {
    public static let formatVersion = 1
    public static let markerFilename = ".noonmark-replication-v2.json"

    public static func openOrCreate(
        at rootURL: URL,
        fileManager: FileManager = .default,
        generationID: @Sendable () -> UUID = UUID.init
    ) throws -> ReplicationRepositoryDescriptor {
        try openOrCreateWithStatus(
            at: rootURL,
            fileManager: fileManager,
            generationID: generationID
        ).descriptor
    }

    public static func openOrCreateWithStatus(
        at rootURL: URL,
        fileManager: FileManager = .default,
        generationID: @Sendable () -> UUID = UUID.init
    ) throws -> ReplicationRepositoryOpenResult {
        try openOrCreateWithStatus(
            at: rootURL,
            fileManager: fileManager,
            generationID: generationID,
            markerWriteByteLimitForTesting: nil
        )
    }

    static func openExistingWithStatus(
        at rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> ReplicationRepositoryOpenResult {
        let root = rootURL.standardizedFileURL
        try requireExistingRoot(root)
        return try withExclusiveBootstrapLock(at: root) {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ReplicationRepositoryBootstrapError
                    .markerUnavailableForExistingAuthority
            }
            guard children.contains(where: {
                $0.lastPathComponent == markerFilename
            }) else {
                throw ReplicationRepositoryBootstrapError
                    .markerUnavailableForExistingAuthority
            }
            return try openPublishedRepository(
                at: root,
                children: children,
                fileManager: fileManager,
                unreadableMarkerError:
                .markerUnavailableForExistingAuthority
            )
        }
    }

    static func openOrCreateWithStatus(
        at rootURL: URL,
        fileManager: FileManager = .default,
        generationID: @Sendable () -> UUID = UUID.init,
        markerWriteByteLimitForTesting: Int?,
        bootstrapLockContendedForTesting: (@Sendable () -> Void)? = nil,
        markerAbsenceObservedForTesting: (@Sendable () throws -> Void)? = nil
    ) throws -> ReplicationRepositoryOpenResult {
        let root = rootURL.standardizedFileURL
        try prepareRoot(root, fileManager: fileManager)
        return try withExclusiveBootstrapLock(
            at: root,
            onLockContention: bootstrapLockContendedForTesting
        ) {
            try openOrCreateLocked(
                at: root,
                fileManager: fileManager,
                generationID: generationID,
                markerWriteByteLimitForTesting: markerWriteByteLimitForTesting,
                markerAbsenceObservedForTesting:
                markerAbsenceObservedForTesting
            )
        }
    }
}

private extension FileReplicationRepositoryBootstrap {
    static func openOrCreateLocked(
        at root: URL,
        fileManager: FileManager,
        generationID: @Sendable () -> UUID,
        markerWriteByteLimitForTesting: Int?,
        markerAbsenceObservedForTesting: (@Sendable () throws -> Void)?
    ) throws -> ReplicationRepositoryOpenResult {
        let markerURL = root.appendingPathComponent(markerFilename)
        if let result = try openPublishedRepositoryIfPresent(
            at: root,
            fileManager: fileManager
        ) {
            return result
        }
        let descriptor = ReplicationRepositoryDescriptor(
            formatVersion: formatVersion,
            generationID: generationID()
        )
        let data = try canonicalData(descriptor)
        try markerAbsenceObservedForTesting?()
        if let result = try openPublishedRepositoryIfPresent(
            at: root,
            fileManager: fileManager
        ) {
            return result
        }
        let children = try directoryChildren(root, fileManager: fileManager)
        if children.isEmpty == false {
            do {
                switch try markerStagingState(
                    at: root,
                    expectedMarkerData: data,
                    fileManager: fileManager
                ) {
                case .recoverable:
                    break
                case .inProgress:
                    if let result = try openPublishedRepositoryIfPresent(
                        at: root,
                        fileManager: fileManager
                    ) {
                        return result
                    }
                    throw ReplicationRepositoryBootstrapError
                        .markerPublicationInProgress
                }
            } catch {
                if let result = try openPublishedRepositoryIfPresent(
                    at: root,
                    fileManager: fileManager
                ) {
                    return result
                }
                throw error
            }
        }
        do {
            let result = try AppendOnlyFilePublisher(
                rootURL: root,
                writeByteLimitForTesting: markerWriteByteLimitForTesting
            ).publish(
                data,
                to: markerFilename,
                stagingArea: "markers"
            )
            switch result {
            case .published:
                return ReplicationRepositoryOpenResult(
                    descriptor: descriptor,
                    createdRepository: true
                )
            case .alreadyPresent:
                return ReplicationRepositoryOpenResult(
                    descriptor: try readMarker(at: markerURL),
                    createdRepository: false
                )
            }
        } catch AppendOnlyFilePublicationError
            .destinationContainsDifferentBytes
        {
            let racedChildren = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
            try validateKnownRootChildren(racedChildren)
            let winner = try readMarker(at: markerURL)
            try validateV2Tree(
                at: root,
                generationID: winner.generationID,
                fileManager: fileManager
            )
            return ReplicationRepositoryOpenResult(
                descriptor: winner,
                createdRepository: false
            )
        } catch {
            throw ReplicationRepositoryBootstrapError.cannotCreateMarker
        }
    }

    static func withExclusiveBootstrapLock<Result>(
        at root: URL,
        onLockContention: (@Sendable () -> Void)? = nil,
        _ operation: () throws -> Result
    ) throws -> Result {
        let descriptor = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        defer { close(descriptor) }

        var lockResult: Int32
        if let onLockContention {
            repeat {
                lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
            } while lockResult != 0 && errno == EINTR
            if lockResult != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw ReplicationRepositoryBootstrapError.invalidBoundary
                }
                onLockContention()
            }
        } else {
            lockResult = -1
        }
        if lockResult != 0 {
            repeat {
                lockResult = flock(descriptor, LOCK_EX)
            } while lockResult != 0 && errno == EINTR
        }
        guard lockResult == 0 else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func prepareRoot(
        _ root: URL,
        fileManager: FileManager
    ) throws {
        guard root.path != "/" else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        var metadata = stat()
        if lstat(root.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & S_IFMT != S_IFLNK
            else {
                throw ReplicationRepositoryBootstrapError.invalidBoundary
            }
            return
        }
        guard errno == ENOENT else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        } catch {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
    }

    static func requireExistingRoot(_ root: URL) throws {
        guard root.path != "/" else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0 else {
            if errno == ENOENT {
                throw ReplicationRepositoryBootstrapError
                    .markerUnavailableForExistingAuthority
            }
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError.invalidBoundary
        }
    }

    static func openPublishedRepositoryIfPresent(
        at root: URL,
        fileManager: FileManager
    ) throws -> ReplicationRepositoryOpenResult? {
        let children = try directoryChildren(root, fileManager: fileManager)
        guard children.contains(where: {
            $0.lastPathComponent == markerFilename
        }) else {
            return nil
        }
        return try openPublishedRepository(
            at: root,
            children: children,
            fileManager: fileManager,
            unreadableMarkerError: .invalidMarker
        )
    }

    static func openPublishedRepository(
        at root: URL,
        children: [URL],
        fileManager: FileManager,
        unreadableMarkerError: ReplicationRepositoryBootstrapError
    ) throws -> ReplicationRepositoryOpenResult {
        try validateKnownRootChildren(children)
        let descriptor = try readMarker(
            at: root.appendingPathComponent(markerFilename),
            unreadableError: unreadableMarkerError
        )
        try validateV2Tree(
            at: root,
            generationID: descriptor.generationID,
            fileManager: fileManager
        )
        return ReplicationRepositoryOpenResult(
            descriptor: descriptor,
            createdRepository: false
        )
    }

    static func validateKnownRootChildren(_ children: [URL]) throws {
        let names = Set(children.map(\.lastPathComponent))
        guard names.contains(markerFilename),
              names.isSubset(of: [markerFilename, "v2"])
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
    }

    enum MarkerStagingState {
        case recoverable
        case inProgress
    }

    static func markerStagingState(
        at root: URL,
        expectedMarkerData: Data,
        fileManager: FileManager
    ) throws -> MarkerStagingState {
        let rootChildren = try directoryChildren(
            root,
            fileManager: fileManager
        )
        guard Set(rootChildren.map(\.lastPathComponent)) == ["v2"],
              let v2 = rootChildren.first
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        try requireDirectory(v2)
        let v2Children = try directoryChildren(v2, fileManager: fileManager)
        guard Set(v2Children.map(\.lastPathComponent)) == ["staging"],
              let staging = v2Children.first
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        try requireDirectory(staging)
        let stagingChildren = try directoryChildren(
            staging,
            fileManager: fileManager
        )
        guard Set(stagingChildren.map(\.lastPathComponent)) == ["markers"],
              let markers = stagingChildren.first
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        try requireDirectory(markers)
        let stagedMarkers = try directoryChildren(
            markers,
            fileManager: fileManager
        )
        var foundCompleteMarker = false
        for staged in stagedMarkers {
            try requireRegularFile(staged)
            let stem = staged.deletingPathExtension().lastPathComponent
            guard staged.pathExtension == "stage",
                  isCanonicalUUID(stem)
            else {
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
            let data: Data
            do {
                data = try Data(contentsOf: staged, options: [.mappedIfSafe])
            } catch {
                throw ReplicationRepositoryBootstrapError
                    .markerPublicationInProgress
            }
            guard data == expectedMarkerData else {
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
            foundCompleteMarker = true
        }
        return foundCompleteMarker ? .recoverable : .inProgress
    }

    static func validateV2Tree(
        at root: URL,
        generationID: UUID,
        fileManager: FileManager
    ) throws {
        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        var information = stat()
        if lstat(v2.path, &information) != 0 {
            guard errno == ENOENT else {
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
            return
        }
        try requireDirectory(v2)
        let children = try directoryChildren(v2, fileManager: fileManager)
        guard Set(children.map(\.lastPathComponent)).isSubset(
            of: ["objects", "announcements", "staging"]
        ) else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        for child in children {
            try requireDirectory(child)
            switch child.lastPathComponent {
            case "objects":
                try validateObjects(child, fileManager: fileManager)
            case "announcements":
                try validateAnnouncements(
                    child,
                    generationID: generationID,
                    fileManager: fileManager
                )
            case "staging":
                try validateStaging(
                    child,
                    allowedAreas: ["markers", "objects"],
                    fileManager: fileManager
                )
            default:
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
        }
    }

    static func validateObjects(
        _ objects: URL,
        fileManager: FileManager
    ) throws {
        let kindNames = Set([
            ReplicationObjectKind.chunk.rawValue,
            ReplicationObjectKind.root.rawValue,
            ReplicationObjectKind.seal.rawValue,
        ])
        let kindDirectories = try directoryChildren(
            objects,
            fileManager: fileManager
        )
        guard Set(kindDirectories.map(\.lastPathComponent))
            .isSubset(of: kindNames)
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        for directory in kindDirectories {
            try requireDirectory(directory)
            for object in try directoryChildren(
                directory,
                fileManager: fileManager
            ) {
                try requireDigestJSONFile(object)
            }
        }
    }

    static func validateStaging(
        _ staging: URL,
        allowedAreas: Set<String>,
        fileManager: FileManager
    ) throws {
        try requireDirectory(staging)
        let areas = try directoryChildren(staging, fileManager: fileManager)
        guard Set(areas.map(\.lastPathComponent)).isSubset(of: allowedAreas)
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        for area in areas {
            try requireDirectory(area)
            for staged in try directoryChildren(
                area,
                fileManager: fileManager
            ) {
                try requireRegularFile(staged)
                let stem = staged.deletingPathExtension().lastPathComponent
                guard staged.pathExtension == "stage",
                      isCanonicalUUID(stem)
                else {
                    throw ReplicationRepositoryBootstrapError
                        .legacyRepositoryRequiresManualReset
                }
            }
        }
    }

    static func validateAnnouncements(
        _ announcements: URL,
        generationID: UUID,
        fileManager: FileManager
    ) throws {
        let generations = try directoryChildren(
            announcements,
            fileManager: fileManager
        )
        let expected = generationID.uuidString.lowercased()
        guard generations.allSatisfy({ $0.lastPathComponent == expected })
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
        for generation in generations {
            try requireDirectory(generation)
            for producer in try directoryChildren(
                generation,
                fileManager: fileManager
            ) {
                try requireDirectory(producer)
                guard isCanonicalUUID(producer.lastPathComponent) else {
                    throw ReplicationRepositoryBootstrapError
                        .legacyRepositoryRequiresManualReset
                }
                try validateAnnouncementSequences(
                    producer,
                    fileManager: fileManager
                )
            }
        }
    }

    static func validateAnnouncementSequences(
        _ producer: URL,
        fileManager: FileManager
    ) throws {
        for sequence in try directoryChildren(
            producer,
            fileManager: fileManager
        ) {
            try requireDirectory(sequence)
            let name = sequence.lastPathComponent
            guard name.count == 20,
                  let value = UInt64(name),
                  value > 0,
                  String(format: "%020llu", value) == name
            else {
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
            let files = try directoryChildren(sequence, fileManager: fileManager)
            guard files.isEmpty == false else {
                throw ReplicationRepositoryBootstrapError
                    .legacyRepositoryRequiresManualReset
            }
            for file in files {
                try requireDigestJSONFile(file)
            }
        }
    }

    static func directoryChildren(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
    }

    static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
    }

    static func requireRegularFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
    }

    static func requireDigestJSONFile(_ url: URL) throws {
        try requireRegularFile(url)
        guard url.pathExtension == "json",
              ReplicationDigest(
                  rawValue: url.deletingPathExtension().lastPathComponent
              ) != nil
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value) else { return false }
        return id.uuidString.lowercased() == value
    }

    static func readMarker(
        at url: URL,
        unreadableError: ReplicationRepositoryBootstrapError = .invalidMarker
    ) throws -> ReplicationRepositoryDescriptor {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw unreadableError
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError.invalidMarker
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw unreadableError
        }
        let descriptor: ReplicationRepositoryDescriptor
        do {
            descriptor = try ReplicationPublicationBuilder
                .canonicalDecoder().decode(
                    ReplicationRepositoryDescriptor.self,
                    from: data
                )
        } catch {
            throw ReplicationRepositoryBootstrapError.invalidMarker
        }
        guard descriptor.formatVersion == formatVersion,
              (try? canonicalData(descriptor)) == data
        else {
            throw ReplicationRepositoryBootstrapError.invalidMarker
        }
        return descriptor
    }

    static func canonicalData(
        _ descriptor: ReplicationRepositoryDescriptor
    ) throws -> Data {
        try ReplicationPublicationBuilder.canonicalEncoder().encode(descriptor)
    }
}
