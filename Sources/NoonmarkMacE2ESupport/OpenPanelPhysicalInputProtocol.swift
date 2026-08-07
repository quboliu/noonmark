import Darwin
import Foundation

public enum OpenPanelPhysicalInputProtocolFailure: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message):
            message
        }
    }
}

public struct OpenPanelPhysicalInputReady: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let status: String
    public let launchToken: String
    public let targetPID: Int
    public let appPath: String
    public let panelWindowNumber: Int
    public let panelLayer: Int
    public let panelTitle: String
    public let selectedPath: String
    public let interactionLabel: String

    public init(
        launchToken: String,
        targetPID: Int,
        appPath: String,
        panelWindowNumber: Int,
        panelLayer: Int,
        panelTitle: String,
        selectedPath: String,
        interactionLabel: String
    ) throws {
        schemaVersion = Self.schemaVersion
        status = "ready"
        self.launchToken = launchToken
        self.targetPID = targetPID
        self.appPath = appPath
        self.panelWindowNumber = panelWindowNumber
        self.panelLayer = panelLayer
        self.panelTitle = panelTitle
        self.selectedPath = selectedPath
        self.interactionLabel = interactionLabel
        try validate()
    }

    fileprivate func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              status == "ready",
              isCanonicalUUID(launchToken),
              targetPID > 0,
              targetPID <= Int(Int32.max),
              panelWindowNumber > 0,
              panelWindowNumber <= Int(UInt32.max),
              panelLayer >= Int(Int32.min),
              panelLayer <= Int(Int32.max),
              isCanonicalExistingAbsolutePath(appPath),
              isCanonicalExistingAbsolutePath(selectedPath),
              isSafeText(panelTitle, maximumUTF8Count: 512),
              isInteractionLabel(interactionLabel)
        else {
            throw OpenPanelPhysicalInputProtocolFailure.invalid(
                "open-panel ready payload violated its exact schema"
            )
        }
    }
}

public struct OpenPanelPhysicalInputCompletion: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let status: String
    public let launchToken: String
    public let helperPID: Int
    public let targetPID: Int
    public let panelWindowNumber: Int
    public let selectedPath: String
    public let interactionLabel: String
    public let buttonTitle: String
    public let source: String
    public let leftButtonUp: Bool

    public init(
        launchToken: String,
        helperPID: Int,
        targetPID: Int,
        panelWindowNumber: Int,
        selectedPath: String,
        interactionLabel: String,
        buttonTitle: String,
        source: String = "cghidEventTap",
        leftButtonUp: Bool
    ) throws {
        schemaVersion = Self.schemaVersion
        status = "complete"
        self.launchToken = launchToken
        self.helperPID = helperPID
        self.targetPID = targetPID
        self.panelWindowNumber = panelWindowNumber
        self.selectedPath = selectedPath
        self.interactionLabel = interactionLabel
        self.buttonTitle = buttonTitle
        self.source = source
        self.leftButtonUp = leftButtonUp
        try validate()
    }

    fileprivate func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              status == "complete",
              isCanonicalUUID(launchToken),
              helperPID > 0,
              helperPID <= Int(Int32.max),
              targetPID > 0,
              targetPID <= Int(Int32.max),
              helperPID != targetPID,
              panelWindowNumber > 0,
              panelWindowNumber <= Int(UInt32.max),
              isCanonicalExistingAbsolutePath(selectedPath),
              isInteractionLabel(interactionLabel),
              ["打开", "Open"].contains(buttonTitle),
              source == "cghidEventTap",
              leftButtonUp
        else {
            throw OpenPanelPhysicalInputProtocolFailure.invalid(
                "open-panel completion payload violated its exact schema"
            )
        }
    }
}

public enum OpenPanelPhysicalInputProtocolFile {
    private static let maximumByteCount = 16 * 1024

    public static func publish(
        _ ready: OpenPanelPhysicalInputReady,
        to url: URL
    ) throws {
        try ready.validate()
        try publishCanonical(ready, to: url)
    }

    public static func publish(
        _ completion: OpenPanelPhysicalInputCompletion,
        to url: URL
    ) throws {
        try completion.validate()
        try publishCanonical(completion, to: url)
    }

    public static func readReady(
        from url: URL
    ) throws -> OpenPanelPhysicalInputReady {
        let data = try readCanonicalData(from: url)
        let value = try JSONDecoder().decode(
            OpenPanelPhysicalInputReady.self,
            from: data
        )
        try value.validate()
        guard try canonicalData(value) == data else {
            throw invalid("open-panel ready file was not canonical")
        }
        return value
    }

    public static func readCompletion(
        from url: URL
    ) throws -> OpenPanelPhysicalInputCompletion {
        let data = try readCanonicalData(from: url)
        let value = try JSONDecoder().decode(
            OpenPanelPhysicalInputCompletion.self,
            from: data
        )
        try value.validate()
        guard try canonicalData(value) == data else {
            throw invalid("open-panel completion file was not canonical")
        }
        return value
    }

    private static func publishCanonical(
        _ value: some Encodable,
        to destination: URL
    ) throws {
        let data = try canonicalData(value)
        guard data.count <= maximumByteCount else {
            throw invalid("open-panel protocol payload exceeded its byte limit")
        }
        try validateOwnerOnlyDirectory(destination.deletingLastPathComponent())
        try requireAbsent(destination)

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        let descriptor = temporary.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return Darwin.open(
                pointer,
                O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor != Int32.min else {
            throw invalid("open-panel protocol temporary path was invalid")
        }
        guard descriptor >= 0 else {
            throw posixFailure("create open-panel protocol temporary", errno)
        }
        var descriptorIsOpen = true
        var temporaryIsPresent = true
        defer {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            if temporaryIsPresent {
                temporary.withUnsafeFileSystemRepresentation { pointer in
                    guard let pointer else { return }
                    _ = Darwin.unlink(pointer)
                }
            }
        }

        try write(data, to: descriptor)
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixFailure("protect open-panel protocol temporary", errno)
        }
        try synchronize(descriptor)
        descriptorIsOpen = false
        guard Darwin.close(descriptor) == 0 else {
            throw posixFailure("close open-panel protocol temporary", errno)
        }

        let renameResult = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32.min }
                return renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult != Int32.min else {
            throw invalid("open-panel protocol publish path was invalid")
        }
        guard renameResult == 0 else {
            throw posixFailure("publish open-panel protocol without overwrite", errno)
        }
        temporaryIsPresent = false
        try synchronizeDirectory(destination.deletingLastPathComponent())
        guard try readCanonicalData(from: destination) == data else {
            throw invalid("published open-panel protocol payload changed")
        }
    }

    private static func readCanonicalData(from url: URL) throws -> Data {
        try validateOwnerOnlyDirectory(url.deletingLastPathComponent())
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return Darwin.open(pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor != Int32.min else {
            throw invalid("open-panel protocol path was invalid")
        }
        guard descriptor >= 0 else {
            throw posixFailure("open open-panel protocol", errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw posixFailure("inspect open-panel protocol", errno)
        }
        guard initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == getuid(),
              initial.st_mode & mode_t(0o777) == mode_t(0o600),
              initial.st_size > 0,
              initial.st_size <= maximumByteCount
        else {
            throw invalid("open-panel protocol was not a bounded owner-only file")
        }

        var data = Data(count: Int(initial.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw count < 0
                    ? posixFailure("read open-panel protocol", errno)
                    : invalid("open-panel protocol read ended early")
            }
            offset += count
        }

        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            throw posixFailure("reinspect open-panel protocol", errno)
        }
        guard initial.st_dev == current.st_dev,
              initial.st_ino == current.st_ino,
              initial.st_size == current.st_size
        else {
            throw invalid("open-panel protocol identity changed during read")
        }
        return data
    }

    private static func canonicalData(
        _ value: some Encodable
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func validateOwnerOnlyDirectory(_ directory: URL) throws {
        var status = stat()
        let result = directory.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &status)
        }
        guard result != Int32.min else {
            throw invalid("open-panel protocol directory path was invalid")
        }
        guard result == 0 else {
            throw posixFailure("inspect open-panel protocol directory", errno)
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw invalid("open-panel protocol directory was not owner-only")
        }
    }

    private static func requireAbsent(_ url: URL) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &status)
        }
        guard result != Int32.min else {
            throw invalid("open-panel protocol destination path was invalid")
        }
        if result == 0 {
            throw invalid("open-panel protocol destination already existed")
        }
        guard errno == ENOENT else {
            throw posixFailure("inspect open-panel protocol destination", errno)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = try data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno != EINTR {
                    throw posixFailure("write open-panel protocol", errno)
                }
                return result
            }
            if count < 0 {
                continue
            }
            guard count > 0 else {
                throw invalid("open-panel protocol write made no progress")
            }
            offset += count
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            throw posixFailure("synchronize open-panel protocol", errno)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return Darwin.open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor != Int32.min else {
            throw invalid("open-panel protocol directory path was invalid")
        }
        guard descriptor >= 0 else {
            throw posixFailure("open open-panel protocol directory", errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor)
    }

    private static func invalid(
        _ message: String
    ) -> OpenPanelPhysicalInputProtocolFailure {
        .invalid(message)
    }

    private static func posixFailure(
        _ operation: String,
        _ code: Int32
    ) -> OpenPanelPhysicalInputProtocolFailure {
        .invalid("\(operation) failed: errno=\(code) \(String(cString: strerror(code)))")
    }
}

private func isCanonicalUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString == value
}

private func isSafeText(_ value: String, maximumUTF8Count: Int) -> Bool {
    value.isEmpty == false
        && value.utf8.count <= maximumUTF8Count
        && value.unicodeScalars.allSatisfy {
            CharacterSet.controlCharacters.contains($0) == false
        }
}

private func isInteractionLabel(_ value: String) -> Bool {
    isSafeText(value, maximumUTF8Count: 96)
        && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
                .contains($0)
        }
}

private func isCanonicalExistingAbsolutePath(_ value: String) -> Bool {
    guard value.hasPrefix("/"),
          isSafeText(value, maximumUTF8Count: 4096)
    else {
        return false
    }
    return URL(fileURLWithPath: value)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path == value
}
