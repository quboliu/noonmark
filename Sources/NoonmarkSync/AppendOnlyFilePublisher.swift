import Darwin
import Foundation

enum AppendOnlyFilePublicationError: Error, Equatable, Sendable {
    case invalidBoundary
    case cannotCreateDirectory
    case cannotCreateStagingFile
    case cannotWriteStagingFile
    case cannotSynchronize
    case destinationContainsDifferentBytes
    case cannotPublish
    case injectedWriteInterruption
}

enum AppendOnlyFilePublicationResult: Equatable, Sendable {
    case published
    case alreadyPresent
}

/// Publishes a file without ever exposing a partially written final key.
///
/// Bytes first land at a unique, permanently retained staging key. After the
/// staged inode is durable, `linkat` creates the final directory entry in one
/// non-overwriting operation. All traversal below the verified root is done
/// through directory descriptors with `O_NOFOLLOW`.
struct AppendOnlyFilePublisher: Sendable {
    let rootURL: URL
    let writeByteLimitForTesting: Int?

    init(
        rootURL: URL,
        writeByteLimitForTesting: Int? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.writeByteLimitForTesting = writeByteLimitForTesting
    }

    func prepareRoot() throws {
        guard rootURL.path != "/" else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        var metadata = stat()
        if lstat(rootURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw AppendOnlyFilePublicationError.invalidBoundary
            }
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw AppendOnlyFilePublicationError.cannotCreateDirectory
            }
            guard lstat(rootURL.path, &metadata) == 0 else {
                throw AppendOnlyFilePublicationError.cannotCreateDirectory
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
    }

    func ensureDirectory(_ relativePath: String) throws {
        try prepareRoot()
        let rootDescriptor = try openRoot()
        defer { close(rootDescriptor) }
        let descriptor = try openDirectoryChain(
            components(relativePath),
            beneath: rootDescriptor,
            createMissing: true
        )
        close(descriptor)
    }

    func publish(
        _ data: Data,
        to relativePath: String,
        stagingArea: String
    ) throws -> AppendOnlyFilePublicationResult {
        try prepareRoot()
        let destination = components(relativePath)
        guard let destinationName = destination.last,
              destination.isEmpty == false
        else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        let area = components(stagingArea)
        guard area.count == 1 else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }

        let rootDescriptor = try openRoot()
        defer { close(rootDescriptor) }
        let destinationDirectory: Int32
        if destination.count == 1 {
            destinationDirectory = dup(rootDescriptor)
            guard destinationDirectory >= 0 else {
                throw AppendOnlyFilePublicationError.invalidBoundary
            }
        } else {
            destinationDirectory = try openDirectoryChain(
                Array(destination.dropLast()),
                beneath: rootDescriptor,
                createMissing: true
            )
        }
        defer { close(destinationDirectory) }

        if let existing = try readIfPresent(
            destinationName,
            from: destinationDirectory
        ) {
            guard existing == data else {
                throw AppendOnlyFilePublicationError
                    .destinationContainsDifferentBytes
            }
            return .alreadyPresent
        }

        let stagingDirectory = try openDirectoryChain(
            ["v2", "staging", area[0]],
            beneath: rootDescriptor,
            createMissing: true
        )
        defer { close(stagingDirectory) }

        let stagingName = UUID().uuidString.lowercased() + ".stage"
        let stagingDescriptor = openat(
            stagingDirectory,
            stagingName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard stagingDescriptor >= 0 else {
            throw AppendOnlyFilePublicationError.cannotCreateStagingFile
        }
        var stagingIsOpen = true
        defer {
            if stagingIsOpen {
                close(stagingDescriptor)
            }
        }

        let byteLimit = writeByteLimitForTesting.map {
            max(0, min($0, data.count))
        } ?? data.count
        try write(data.prefix(byteLimit), to: stagingDescriptor)
        guard fsync(stagingDescriptor) == 0 else {
            throw AppendOnlyFilePublicationError.cannotSynchronize
        }
        guard close(stagingDescriptor) == 0 else {
            stagingIsOpen = false
            throw AppendOnlyFilePublicationError.cannotSynchronize
        }
        stagingIsOpen = false

        if writeByteLimitForTesting != nil, byteLimit < data.count {
            throw AppendOnlyFilePublicationError.injectedWriteInterruption
        }

        let linkResult = stagingName.withCString { source in
            destinationName.withCString { target in
                linkat(
                    stagingDirectory,
                    source,
                    destinationDirectory,
                    target,
                    0
                )
            }
        }
        if linkResult == 0 {
            guard fsync(destinationDirectory) == 0,
                  fsync(stagingDirectory) == 0
            else {
                throw AppendOnlyFilePublicationError.cannotSynchronize
            }
            return .published
        }
        guard errno == EEXIST else {
            throw AppendOnlyFilePublicationError.cannotPublish
        }
        guard try readIfPresent(
            destinationName,
            from: destinationDirectory
        ) == data else {
            throw AppendOnlyFilePublicationError
                .destinationContainsDifferentBytes
        }
        return .alreadyPresent
    }
}

private extension AppendOnlyFilePublisher {
    func components(_ relativePath: String) -> [String] {
        guard relativePath.isEmpty == false,
              relativePath.hasPrefix("/") == false,
              relativePath.utf8.contains(0) == false
        else { return [] }
        let result = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard result.allSatisfy({
            $0.isEmpty == false && $0 != "." && $0 != ".."
        }) else { return [] }
        return result
    }

    func openRoot() throws -> Int32 {
        let descriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        return descriptor
    }

    func openDirectoryChain(
        _ pathComponents: [String],
        beneath rootDescriptor: Int32,
        createMissing: Bool
    ) throws -> Int32 {
        guard pathComponents.isEmpty == false,
              pathComponents.allSatisfy({
                  $0.isEmpty == false && $0 != "." && $0 != ".."
                      && $0.utf8.contains(0) == false
              })
        else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        do {
            for component in pathComponents {
                if createMissing {
                    let result = component.withCString {
                        mkdirat(current, $0, mode_t(S_IRWXU))
                    }
                    guard result == 0 || errno == EEXIST else {
                        throw AppendOnlyFilePublicationError
                            .cannotCreateDirectory
                    }
                }
                let next = component.withCString {
                    openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard next >= 0 else {
                    throw AppendOnlyFilePublicationError.invalidBoundary
                }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    func write(_ data: Data.SubSequence, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw AppendOnlyFilePublicationError
                        .cannotWriteStagingFile
                }
            }
        }
    }

    func readIfPresent(
        _ name: String,
        from directory: Int32
    ) throws -> Data? {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AppendOnlyFilePublicationError.cannotPublish
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            throw AppendOnlyFilePublicationError.invalidBoundary
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(buffer, count: count)
            } else if count == 0 {
                return result
            } else if errno == EINTR {
                continue
            } else {
                throw AppendOnlyFilePublicationError.cannotPublish
            }
        }
    }
}
