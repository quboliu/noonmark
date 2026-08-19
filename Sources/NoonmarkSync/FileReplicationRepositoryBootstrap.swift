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

    static func openOrCreateWithStatus(
        at rootURL: URL,
        fileManager: FileManager = .default,
        generationID: @Sendable () -> UUID = UUID.init,
        markerWriteByteLimitForTesting: Int?
    ) throws -> ReplicationRepositoryOpenResult {
        let root = rootURL.standardizedFileURL
        try prepareRoot(root, fileManager: fileManager)
        return try withExclusiveBootstrapLock(at: root) {
            try openOrCreateLocked(
                at: root,
                fileManager: fileManager,
                generationID: generationID,
                markerWriteByteLimitForTesting: markerWriteByteLimitForTesting
            )
        }
    }
}

private extension FileReplicationRepositoryBootstrap {
    static func openOrCreateLocked(
        at root: URL,
        fileManager: FileManager,
        generationID: @Sendable () -> UUID,
        markerWriteByteLimitForTesting: Int?
    ) throws -> ReplicationRepositoryOpenResult {
        let markerURL = root.appendingPathComponent(markerFilename)
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        if children.contains(where: { $0.lastPathComponent == markerFilename }) {
            try validateKnownRootChildren(children)
            let descriptor = try readMarker(at: markerURL)
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
        guard children.isEmpty else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }

        let descriptor = ReplicationRepositoryDescriptor(
            formatVersion: formatVersion,
            generationID: generationID()
        )
        let data = try canonicalData(descriptor)
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
        repeat {
            lockResult = flock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
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

    static func validateKnownRootChildren(_ children: [URL]) throws {
        let names = Set(children.map(\.lastPathComponent))
        guard names.contains(markerFilename),
              names.isSubset(of: [markerFilename, "v2"])
        else {
            throw ReplicationRepositoryBootstrapError
                .legacyRepositoryRequiresManualReset
        }
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
        at url: URL
    ) throws -> ReplicationRepositoryDescriptor {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw ReplicationRepositoryBootstrapError.invalidMarker
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ReplicationRepositoryBootstrapError.invalidMarker
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
