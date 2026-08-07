import CoreFoundation
import Darwin
import Foundation

/// Publishes one App-owned WindowServer identity without requiring an external
/// process to enumerate unrelated applications' windows.
///
/// Production returns before any filesystem access. E2E explicitly supplies a
/// per-launch destination and token. DMG validation uses a fixed, owner-only
/// request/response directory below its own Application Support scope.
public final class MainWindowIdentityPublisher {
    struct Preparation {
        let profile: NoonmarkRuntimeProfile
        let bundleIdentifier: String?
        let processArguments: [String]
        let applicationSupportBaseURL: URL
        let homeDirectoryURL: URL
    }

    public static let schemaVersion = 1
    public static let runtimeEvidenceDirectoryName = "RuntimeEvidence"
    public static let requestFileName = "main-window-request.json"
    public static let identityFileName = "main-window-identity.json"
    public static let e2eIdentityURLArgument =
        "--e2e-main-window-identity-url"
    public static let e2eLaunchTokenArgument =
        "--e2e-main-window-launch-token"

    private static let maximumProtocolByteCount = 4 * 1024
    private static let maximumTitleByteCount = 512
    private static let ownerOnlyDirectoryPermissions = mode_t(0o700)
    private static let ownerOnlyFilePermissions = mode_t(0o600)

    public let profile: NoonmarkRuntimeProfile
    public let launchToken: String

    private let directoryDescriptor: Int32
    private let publicationLock = NSLock()
    private var didPublish = false

    private init(
        profile: NoonmarkRuntimeProfile,
        launchToken: String,
        directoryDescriptor: Int32
    ) {
        self.profile = profile
        self.launchToken = launchToken
        self.directoryDescriptor = directoryDescriptor
    }

    deinit {
        _ = Darwin.close(directoryDescriptor)
    }

    public static func prepare(
        profile: NoonmarkRuntimeProfile,
        bundleIdentifier: String?,
        processArguments: [String],
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL
    ) throws -> MainWindowIdentityPublisher? {
        try prepare(
            Preparation(
                profile: profile,
                bundleIdentifier: bundleIdentifier,
                processArguments: processArguments,
                applicationSupportBaseURL: applicationSupportBaseURL,
                homeDirectoryURL: homeDirectoryURL
            ),
            requestIdentityCapturedHook: nil
        )
    }

    static func prepare(
        _ preparation: Preparation,
        requestIdentityCapturedHook: (() throws -> Void)?
    ) throws -> MainWindowIdentityPublisher? {
        // This guard must remain before bundle, argument, URL, or filesystem
        // inspection. Production does not participate in this protocol.
        guard preparation.profile != .production else { return nil }

        switch preparation.profile {
        case .e2e:
            return try prepareE2E(
                bundleIdentifier: preparation.bundleIdentifier,
                processArguments: preparation.processArguments,
                applicationSupportBaseURL:
                    preparation.applicationSupportBaseURL,
                homeDirectoryURL: preparation.homeDirectoryURL
            )
        case .dmgValidation:
            return try prepareDMGValidation(
                bundleIdentifier: preparation.bundleIdentifier,
                applicationSupportBaseURL:
                    preparation.applicationSupportBaseURL,
                homeDirectoryURL: preparation.homeDirectoryURL,
                requestIdentityCapturedHook: requestIdentityCapturedHook
            )
        case .production, .development, .demo, .audit:
            return nil
        }
    }

    public func publish(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        windowNumber: Int,
        title: String
    ) throws {
        publicationLock.lock()
        defer { publicationLock.unlock() }

        guard didPublish == false else {
            throw MainWindowIdentityPublicationError.alreadyPublished
        }
        guard processIdentifier == getpid(),
              processIdentifier > 0,
              bundleIdentifier == profile.bundleIdentifier,
              windowNumber > 0,
              title.isEmpty == false,
              title.utf8.count <= Self.maximumTitleByteCount,
              Self.isControlFree(title)
        else {
            throw MainWindowIdentityPublicationError.invalidIdentity
        }

        let response = MainWindowIdentityResponse(
            schemaVersion: Self.schemaVersion,
            profile: profile.rawValue,
            launchToken: launchToken,
            processIdentifier: Int(processIdentifier),
            bundleIdentifier: bundleIdentifier,
            windowNumber: windowNumber,
            title: title
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            throw MainWindowIdentityPublicationError.invalidIdentity
        }
        guard data.isEmpty == false,
              data.count <= Self.maximumProtocolByteCount
        else {
            throw MainWindowIdentityPublicationError.invalidIdentity
        }

        try Self.requireMissingEntry(
            named: Self.identityFileName,
            in: directoryDescriptor
        )
        try Self.writeAtomically(
            data,
            named: Self.identityFileName,
            in: directoryDescriptor
        )
        didPublish = true
    }

    private static func prepareE2E(
        bundleIdentifier: String?,
        processArguments: [String],
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL
    ) throws -> MainWindowIdentityPublisher? {
        guard bundleIdentifier == NoonmarkRuntimeProfile.e2e.bundleIdentifier
        else {
            throw MainWindowIdentityPublicationError.invalidBundleIdentifier
        }
        let destinationValues = values(
            after: e2eIdentityURLArgument,
            in: processArguments
        )
        let tokenValues = values(
            after: e2eLaunchTokenArgument,
            in: processArguments
        )
        guard destinationValues.isEmpty == false || tokenValues.isEmpty == false
        else {
            return nil
        }
        guard destinationValues.count == 1,
              tokenValues.count == 1,
              let destinationPath = destinationValues.first,
              destinationPath.hasPrefix("/"),
              let launchToken = tokenValues.first,
              isCanonicalLaunchToken(launchToken)
        else {
            throw MainWindowIdentityPublicationError.invalidArguments
        }

        let rawDestinationURL = URL(fileURLWithPath: destinationPath)
        let destinationURL = URL(
            fileURLWithPath: NoonmarkRuntimeProfile.normalizedLexicalPath(
                for: rawDestinationURL
            )
        )
        guard destinationURL.lastPathComponent == identityFileName else {
            throw MainWindowIdentityPublicationError.invalidPath
        }
        try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
            destinationURL,
            protectedProductionRoots: protectedProductionRoots(
                applicationSupportBaseURL: applicationSupportBaseURL,
                homeDirectoryURL: homeDirectoryURL
            )
        )
        let directoryDescriptor = try openOwnedDirectory(
            at: destinationURL.deletingLastPathComponent(),
            exactPermissions: ownerOnlyDirectoryPermissions
        )
        do {
            try requireMissingEntry(
                named: identityFileName,
                in: directoryDescriptor
            )
            return MainWindowIdentityPublisher(
                profile: .e2e,
                launchToken: launchToken,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            _ = Darwin.close(directoryDescriptor)
            throw error
        }
    }

    private static func prepareDMGValidation(
        bundleIdentifier: String?,
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL,
        requestIdentityCapturedHook: (() throws -> Void)?
    ) throws -> MainWindowIdentityPublisher? {
        guard bundleIdentifier == NoonmarkRuntimeProfile.dmgValidation
            .bundleIdentifier
        else {
            throw MainWindowIdentityPublicationError.invalidBundleIdentifier
        }
        guard applicationSupportBaseURL.isFileURL else {
            throw MainWindowIdentityPublicationError.invalidPath
        }

        let profileURL = NoonmarkRuntimeProfile.dmgValidation
            .applicationSupportRootURL(baseURL: applicationSupportBaseURL)
        try NoonmarkRuntimeProfile.dmgValidation.validateInternalPathOverride(
            profileURL,
            protectedProductionRoots: protectedProductionRoots(
                applicationSupportBaseURL: applicationSupportBaseURL,
                homeDirectoryURL: homeDirectoryURL
            )
        )
        guard let profileDescriptor = try openOptionalOwnedDirectory(
            at: profileURL,
            exactPermissions: nil
        ) else {
            return nil
        }
        defer { _ = Darwin.close(profileDescriptor) }

        let runtimeDescriptor = openat(
            profileDescriptor,
            runtimeEvidenceDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard runtimeDescriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw posixError()
        }
        do {
            try validateOwnedDirectory(
                runtimeDescriptor,
                exactPermissions: ownerOnlyDirectoryPermissions
            )
            guard let requestData = try readOwnedRegularFile(
                named: requestFileName,
                from: runtimeDescriptor,
                maximumByteCount: maximumProtocolByteCount,
                identityCapturedHook: requestIdentityCapturedHook
            ) else {
                _ = Darwin.close(runtimeDescriptor)
                return nil
            }
            let launchToken = try parseDMGValidationRequest(requestData)
            try requireMissingEntry(
                named: identityFileName,
                in: runtimeDescriptor
            )
            return MainWindowIdentityPublisher(
                profile: .dmgValidation,
                launchToken: launchToken,
                directoryDescriptor: runtimeDescriptor
            )
        } catch {
            _ = Darwin.close(runtimeDescriptor)
            throw error
        }
    }

    private static func values(
        after flag: String,
        in arguments: [String]
    ) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag else { return nil }
            let valueIndex = arguments.index(after: index)
            guard arguments.indices.contains(valueIndex),
                  arguments[valueIndex].hasPrefix("--") == false,
                  arguments[valueIndex].isEmpty == false
            else {
                return ""
            }
            return arguments[valueIndex]
        }
    }

    private static func protectedProductionRoots(
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL
    ) -> [URL] {
        let productionApplicationSupportRoot = NoonmarkRuntimeProfile
            .production
            .applicationSupportRootURL(baseURL: applicationSupportBaseURL)
        let productionICloudRoot = homeDirectoryURL.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        ).appendingPathComponent(
            NoonmarkRuntimeProfile.production.iCloudRepositoryName,
            isDirectory: true
        )
        return [productionApplicationSupportRoot, productionICloudRoot]
    }

    private static func parseDMGValidationRequest(_ data: Data) throws -> String {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            else {
                throw MainWindowIdentityPublicationError.invalidRequest
            }
            object = decoded
        } catch let error as MainWindowIdentityPublicationError {
            throw error
        } catch {
            throw MainWindowIdentityPublicationError.invalidRequest
        }
        guard Set(object.keys) == [
            "schema_version", "profile", "launch_token"
        ],
            exactInteger(object["schema_version"]) == schemaVersion,
            object["profile"] as? String
                == NoonmarkRuntimeProfile.dmgValidation.rawValue,
            let launchToken = object["launch_token"] as? String,
            isCanonicalLaunchToken(launchToken)
        else {
            throw MainWindowIdentityPublicationError.invalidRequest
        }
        let canonicalData: Data
        do {
            canonicalData = try JSONSerialization.data(
                withJSONObject: [
                    "schema_version": schemaVersion,
                    "profile": NoonmarkRuntimeProfile.dmgValidation.rawValue,
                    "launch_token": launchToken
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw MainWindowIdentityPublicationError.invalidRequest
        }
        guard canonicalData == data else {
            throw MainWindowIdentityPublicationError.invalidRequest
        }
        return launchToken
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            return nil
        }
        return number.intValue
    }

    private static func isCanonicalLaunchToken(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              isControlFree(value),
              let identifier = UUID(uuidString: value)
        else {
            return false
        }
        return identifier.uuidString == value
    }

    private static func isControlFree(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            CharacterSet.controlCharacters.contains($0) == false
        }
    }

    private static func openOptionalOwnedDirectory(
        at url: URL,
        exactPermissions: mode_t?
    ) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw MainWindowIdentityPublicationError.invalidPath
        }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError() }
        for component in url.path.split(separator: "/") {
            let nextDescriptor = openat(
                descriptor,
                String(component),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let openError = nextDescriptor >= 0 ? 0 : errno
            _ = Darwin.close(descriptor)
            guard nextDescriptor >= 0 else {
                if openError == ENOENT {
                    return nil
                }
                throw MainWindowIdentityPublicationError.posix(openError)
            }
            descriptor = nextDescriptor
        }
        do {
            try validateOwnedDirectory(
                descriptor,
                exactPermissions: exactPermissions
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openOwnedDirectory(
        at url: URL,
        exactPermissions: mode_t
    ) throws -> Int32 {
        guard let descriptor = try openOptionalOwnedDirectory(
            at: url,
            exactPermissions: exactPermissions
        ) else {
            throw MainWindowIdentityPublicationError.invalidPath
        }
        return descriptor
    }

    private static func validateOwnedDirectory(
        _ descriptor: Int32,
        exactPermissions: mode_t?
    ) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError()
        }
        let permissions = information.st_mode & mode_t(0o777)
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == geteuid(),
              permissions & mode_t(0o022) == 0,
              exactPermissions == nil || permissions == exactPermissions
        else {
            throw MainWindowIdentityPublicationError.unsafeDirectory
        }
    }

    private static func readOwnedRegularFile(
        named name: String,
        from directoryDescriptor: Int32,
        maximumByteCount: Int,
        identityCapturedHook: (() throws -> Void)?
    ) throws -> Data? {
        var pathInformation = stat()
        guard fstatat(
            directoryDescriptor,
            name,
            &pathInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw posixError()
        }
        try validateOwnedRegularFile(
            pathInformation,
            maximumByteCount: maximumByteCount,
            requiresContent: true
        )
        try identityCapturedHook?()

        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }

        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0 else {
            throw posixError()
        }
        try validateOwnedRegularFile(
            openedInformation,
            maximumByteCount: maximumByteCount,
            requiresContent: true
        )
        guard sameSnapshot(pathInformation, openedInformation) else {
            throw MainWindowIdentityPublicationError.unsafeRequest
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumByteCount + 1)
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw posixError()
        }

        var finalInformation = stat()
        var finalPathInformation = stat()
        guard data.count <= maximumByteCount,
              fstat(descriptor, &finalInformation) == 0,
              fstatat(
                  directoryDescriptor,
                  name,
                  &finalPathInformation,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameSnapshot(openedInformation, finalInformation),
              sameSnapshot(openedInformation, finalPathInformation),
              finalInformation.st_size == data.count
        else {
            throw MainWindowIdentityPublicationError.unsafeRequest
        }
        try validateOwnedRegularFile(
            finalInformation,
            maximumByteCount: maximumByteCount,
            requiresContent: true
        )
        return data
    }

    private static func validateOwnedRegularFile(
        _ information: stat,
        maximumByteCount: Int,
        requiresContent: Bool
    ) throws {
        let sizeIsValid = information.st_size >= (requiresContent ? 1 : 0)
            && information.st_size <= maximumByteCount
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & mode_t(0o777)
                == ownerOnlyFilePermissions,
              sizeIsValid
        else {
            throw MainWindowIdentityPublicationError.unsafeRequest
        }
    }

    private static func requireMissingEntry(
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        var information = stat()
        guard fstatat(
            directoryDescriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) != 0 else {
            throw MainWindowIdentityPublicationError.staleIdentity
        }
        guard errno == ENOENT else { throw posixError() }
    }

    private static func writeAtomically(
        _ data: Data,
        named destinationName: String,
        in directoryDescriptor: Int32
    ) throws {
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = try openPreparedTemporaryFile(
            named: temporaryName,
            in: directoryDescriptor
        )
        var removesTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if removesTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try writeAll(data, to: descriptor)
        try synchronize(descriptor)
        try renameExclusively(
            temporaryName,
            to: destinationName,
            in: directoryDescriptor
        )
        removesTemporaryFile = false
        try synchronize(directoryDescriptor)
        try validatePublishedIdentity(
            named: destinationName,
            fileDescriptor: descriptor,
            directoryDescriptor: directoryDescriptor
        )
    }

    private static func openPreparedTemporaryFile(
        named temporaryName: String,
        in directoryDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            ownerOnlyFilePermissions
        )
        guard descriptor >= 0 else { throw posixError() }
        guard fchmod(descriptor, ownerOnlyFilePermissions) == 0 else {
            let failure = MainWindowIdentityPublicationError.posix(errno)
            _ = Darwin.close(descriptor)
            _ = unlinkat(directoryDescriptor, temporaryName, 0)
            throw failure
        }
        var information = stat()
        do {
            guard fstat(descriptor, &information) == 0 else {
                throw posixError()
            }
            try validateOwnedRegularFile(
                information,
                maximumByteCount: maximumProtocolByteCount,
                requiresContent: false
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            _ = unlinkat(directoryDescriptor, temporaryName, 0)
            throw error
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            throw posixError()
        }
    }

    private static func renameExclusively(
        _ sourceName: String,
        to destinationName: String,
        in directoryDescriptor: Int32
    ) throws {
        guard renameatx_np(
            directoryDescriptor,
            sourceName,
            directoryDescriptor,
            destinationName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posixError()
        }
    }

    private static func validatePublishedIdentity(
        named destinationName: String,
        fileDescriptor: Int32,
        directoryDescriptor: Int32
    ) throws {
        var writtenInformation = stat()
        var publishedInformation = stat()
        var confirmedPublishedInformation = stat()
        guard fstatat(
            directoryDescriptor,
            destinationName,
            &publishedInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixError()
        }
        guard fstat(fileDescriptor, &writtenInformation) == 0 else {
            throw posixError()
        }
        guard sameSnapshot(writtenInformation, publishedInformation) else {
            throw MainWindowIdentityPublicationError
                .publicationIdentityChanged
        }
        guard fstatat(
            directoryDescriptor,
            destinationName,
            &confirmedPublishedInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixError()
        }
        guard sameSnapshot(
            writtenInformation,
            confirmedPublishedInformation
        ) else {
            throw MainWindowIdentityPublicationError
                .publicationIdentityChanged
        }
        try validateOwnedRegularFile(
            publishedInformation,
            maximumByteCount: maximumProtocolByteCount,
            requiresContent: true
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw MainWindowIdentityPublicationError.invalidIdentity
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw posixError()
            }
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func posixError() -> MainWindowIdentityPublicationError {
        .posix(errno)
    }
}

private struct MainWindowIdentityResponse: Encodable {
    let schemaVersion: Int
    let profile: String
    let launchToken: String
    let processIdentifier: Int
    let bundleIdentifier: String
    let windowNumber: Int
    let title: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profile
        case launchToken = "launch_token"
        case processIdentifier = "process_identifier"
        case bundleIdentifier = "bundle_identifier"
        case windowNumber = "window_number"
        case title
    }
}

public enum MainWindowIdentityPublicationError: Error, Equatable, Sendable {
    case invalidBundleIdentifier
    case invalidArguments
    case invalidPath
    case unsafeDirectory
    case unsafeRequest
    case invalidRequest
    case staleIdentity
    case invalidIdentity
    case alreadyPublished
    case publicationIdentityChanged
    case posix(Int32)
}
