import Darwin
import Foundation

final class DiagnosticOwnedDirectory {
    struct EntryInformation {
        let mode: mode_t
        let logicalByteCount: Int64
        let allocatedByteCount: Int64
        let modificationDate: Date

        var isRegularFile: Bool {
            mode & S_IFMT == S_IFREG
        }
    }

    struct VerifiedFile {
        let data: Data
        let information: EntryInformation
    }

    let descriptor: Int32

    private init(descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid()
        else {
            Darwin.close(descriptor)
            throw DiagnosticStorageError.invalidRoot
        }
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func openRoot(
        at url: URL,
        permissions: mode_t,
        fileManager: FileManager
    ) throws -> DiagnosticOwnedDirectory {
        let standardizedURL = url.standardizedFileURL
        let parentURL = standardizedURL.deletingLastPathComponent()
        let name = standardizedURL.lastPathComponent
        try validateEntryName(name)
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(permissions)]
        )
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(parentDescriptor) }
        if mkdirat(parentDescriptor, name, permissions) != 0,
           errno != EEXIST
        {
            throw currentPOSIXError()
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DiagnosticStorageError.invalidRoot
        }
        guard fchmod(descriptor, permissions) == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }
        return try DiagnosticOwnedDirectory(descriptor: descriptor)
    }

    func openChildDirectory(
        named name: String,
        createIfMissing: Bool,
        permissions: mode_t
    ) throws -> DiagnosticOwnedDirectory? {
        try Self.validateEntryName(name)
        if createIfMissing,
           mkdirat(descriptor, name, permissions) != 0,
           errno != EEXIST
        {
            throw Self.currentPOSIXError()
        }
        let childDescriptor = openat(
            descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard childDescriptor >= 0 else {
            if errno == ENOENT, createIfMissing == false {
                return nil
            }
            throw DiagnosticStorageError.invalidRoot
        }
        guard fchmod(childDescriptor, permissions) == 0 else {
            let error = Self.currentPOSIXError()
            Darwin.close(childDescriptor)
            throw error
        }
        return try DiagnosticOwnedDirectory(descriptor: childDescriptor)
    }

    func entryInformation(named name: String) throws -> EntryInformation? {
        try Self.validateEntryName(name)
        var information = stat()
        guard fstatat(
            descriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.currentPOSIXError()
        }
        var allocatedByteCount: Int64
        if information.st_mode & S_IFMT == S_IFREG {
            let fileDescriptor = openat(
                descriptor,
                name,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard fileDescriptor >= 0 else {
                throw Self.currentPOSIXError()
            }
            defer { Darwin.close(fileDescriptor) }
            var openedInformation = stat()
            guard fstat(fileDescriptor, &openedInformation) == 0,
                  Self.isOwnedRegularFile(openedInformation),
                  openedInformation.st_dev == information.st_dev,
                  openedInformation.st_ino == information.st_ino
            else {
                throw DiagnosticStorageError.invalidRoot
            }
            information = openedInformation
            allocatedByteCount = try Self.allocatedByteCount(
                of: fileDescriptor
            )
        } else {
            let (fallback, overflow) = Int64(information.st_blocks)
                .multipliedReportingOverflow(by: 512)
            guard overflow == false, fallback >= 0 else {
                throw DiagnosticStorageError.allocatedSizeUnavailable
            }
            allocatedByteCount = fallback
        }
        guard information.st_size >= 0 else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        return EntryInformation(
            mode: information.st_mode,
            logicalByteCount: Int64(information.st_size),
            allocatedByteCount: allocatedByteCount,
            modificationDate: Self.date(from: information.st_mtimespec)
        )
    }

    func readFile(
        named name: String,
        maximumByteCount: Int64
    ) throws -> Data {
        try readVerifiedFile(
            named: name,
            maximumByteCount: maximumByteCount
        ).data
    }

    func readVerifiedFile(
        named name: String,
        maximumByteCount: Int64,
        identityCapturedHook: (() throws -> Void)? = nil
    ) throws -> VerifiedFile {
        try Self.validateEntryName(name)
        var capturedInformation = stat()
        guard fstatat(
            descriptor,
            name,
            &capturedInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            Self.isOwnedRegularFile(capturedInformation)
        else {
            throw DiagnosticStorageError.invalidRoot
        }
        try identityCapturedHook?()
        let fileDescriptor = openat(
            descriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else { throw Self.currentPOSIXError() }
        defer { Darwin.close(fileDescriptor) }
        var openedInformation = stat()
        guard fstat(fileDescriptor, &openedInformation) == 0,
              Self.isOwnedRegularFile(openedInformation),
              openedInformation.st_dev == capturedInformation.st_dev,
              openedInformation.st_ino == capturedInformation.st_ino
        else {
            throw DiagnosticStorageError.invalidRoot
        }
        guard openedInformation.st_size >= 0,
              openedInformation.st_size <= maximumByteCount
        else {
            throw DiagnosticStorageError.exportTooLarge
        }
        let allocatedByteCount = try Self.allocatedByteCount(
            of: fileDescriptor
        )
        let data = try Self.readBoundedData(
            from: fileDescriptor,
            knownInformation: openedInformation,
            maximumByteCount: maximumByteCount
        )
        return VerifiedFile(
            data: data,
            information: EntryInformation(
                mode: openedInformation.st_mode,
                logicalByteCount: Int64(openedInformation.st_size),
                allocatedByteCount: allocatedByteCount,
                modificationDate: Self.date(
                    from: openedInformation.st_mtimespec
                )
            )
        )
    }

    func entryModificationDateWithoutOpening(named name: String) throws
        -> Date?
    {
        try Self.validateEntryName(name)
        var information = stat()
        guard fstatat(
            descriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.currentPOSIXError()
        }
        return Self.date(from: information.st_mtimespec)
    }

    private static func readBoundedData(
        from fileDescriptor: Int32,
        knownInformation information: stat,
        maximumByteCount: Int64
    ) throws -> Data {
        let limit = Int(min(max(0, maximumByteCount), Int64(Int.max - 1)))
        var data = Data()
        data.reserveCapacity(min(Int(information.st_size), limit))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limit + 1))
        repeat {
            let remaining = limit + 1 - data.count
            guard remaining > 0 else {
                throw DiagnosticStorageError.exportTooLarge
            }
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.currentPOSIXError()
            }
            data.append(contentsOf: buffer.prefix(count))
        } while true
        guard data.count <= limit else {
            throw DiagnosticStorageError.exportTooLarge
        }
        return data
    }

    func appendFile(named name: String, data: Data) throws {
        try Self.validateEntryName(name)
        let fileDescriptor = openat(
            descriptor,
            name,
            O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else { throw Self.currentPOSIXError() }
        defer { Darwin.close(fileDescriptor) }
        try Self.prepareRegularFile(fileDescriptor)
        try Self.writeAll(data, to: fileDescriptor)
    }

    func writeNewFile(named name: String, data: Data) throws {
        try Self.validateEntryName(name)
        let fileDescriptor = openat(
            descriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else { throw Self.currentPOSIXError() }
        defer { Darwin.close(fileDescriptor) }
        try Self.prepareRegularFile(fileDescriptor)
        try Self.writeAll(data, to: fileDescriptor)
    }

    func removeEntryIfPresent(named name: String) throws {
        try Self.validateEntryName(name)
        guard unlinkat(descriptor, name, 0) == 0 else {
            if errno == ENOENT { return }
            throw Self.currentPOSIXError()
        }
    }

    func renameEntry(named source: String, to destination: String) throws {
        try Self.validateEntryName(source)
        try Self.validateEntryName(destination)
        guard renameat(descriptor, source, descriptor, destination) == 0 else {
            throw Self.currentPOSIXError()
        }
    }

    func entryNames() throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else {
            throw Self.currentPOSIXError()
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            let error = Self.currentPOSIXError()
            Darwin.close(enumerationDescriptor)
            throw error
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.currentPOSIXError() }
                break
            }
            let nameLength = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(nameLength), encoding: .utf8)
            }
            guard let name else { throw DiagnosticStorageError.invalidRoot }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    func synchronize() throws {
        try Self.synchronizeDescriptor(descriptor)
    }

    func fileSystemBlockSize() -> Int64? {
        var information = statfs()
        guard fstatfs(descriptor, &information) == 0 else { return nil }
        return max(4096, Int64(information.f_bsize))
    }

    private static func prepareRegularFile(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              isOwnedRegularFile(information),
              fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw DiagnosticStorageError.invalidRoot
        }
    }

    private static func isOwnedRegularFile(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == geteuid()
            && information.st_nlink == 1
    }

    private static func allocatedByteCount(of descriptor: Int32) throws
        -> Int64
    {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)
        var buffer = [UInt8](repeating: 0, count: 32)
        let result = buffer.withUnsafeMutableBytes { bytes in
            fgetattrlist(
                descriptor,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        guard result == 0 else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        let values = buffer.withUnsafeBytes { bytes -> (UInt32, Int64) in
            (
                bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                bytes.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            )
        }
        guard values.0 >= 12,
              Int(values.0) <= buffer.count,
              values.1 >= 0
        else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        return values.1
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                try synchronizeDescriptor(descriptor)
                return
            }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
            try synchronizeDescriptor(descriptor)
        }
    }

    private static func synchronizeDescriptor(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private static func validateEntryName(_ name: String) throws {
        guard name.isEmpty == false,
              name != ".",
              name != "..",
              name.contains("/") == false,
              name.contains("\0") == false
        else {
            throw DiagnosticStorageError.invalidRoot
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func date(from value: timespec) -> Date {
        let seconds = TimeInterval(value.tv_sec)
            + TimeInterval(value.tv_nsec) / 1_000_000_000
        guard seconds.isFinite else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }
}
