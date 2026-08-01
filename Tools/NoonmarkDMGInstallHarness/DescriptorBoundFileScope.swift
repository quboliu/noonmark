import Darwin
import Foundation

struct CanonicalAbsolutePath: Equatable, Hashable {
    let components: [String]

    init(_ rawValue: String) throws {
        guard rawValue.first == "/",
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              })
        else {
            throw Self.contract("path is not an absolute single-line path")
        }
        if rawValue == "/" {
            components = []
            return
        }
        let pieces = rawValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let tail = pieces.dropFirst().map(String.init)
        guard pieces.first?.isEmpty == true,
              tail.isEmpty == false,
              tail.allSatisfy({ component in
                  component.isEmpty == false
                      && component != "."
                      && component != ".."
              }),
              "/" + tail.joined(separator: "/") == rawValue
        else {
            throw Self.contract("path has noncanonical lexical components")
        }
        components = tail
    }

    var string: String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    var lastComponent: String? {
        components.last
    }

    var parent: CanonicalAbsolutePath {
        CanonicalAbsolutePath(components: Array(components.dropLast()))
    }

    func appending(_ component: String) throws -> CanonicalAbsolutePath {
        try Self.validate(component: component)
        return CanonicalAbsolutePath(components: components + [component])
    }

    func isSameOrDescendant(of root: CanonicalAbsolutePath) -> Bool {
        guard components.count >= root.components.count else { return false }
        return zip(components, root.components).allSatisfy { candidate, expected in
            candidate.lowercased() == expected.lowercased()
        }
    }

    static func validate(component: String) throws {
        guard component.isEmpty == false,
              component != ".",
              component != "..",
              component.contains("/") == false,
              component.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              })
        else {
            throw contract("path component is not canonical")
        }
    }

    private init(components: [String]) {
        self.components = components
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }
}

final class DescriptorBoundDirectory {
    let path: CanonicalAbsolutePath
    let descriptor: Int32
    let identity: stat

    init(
        path: CanonicalAbsolutePath,
        afterIdentityCapture: () throws -> Void = {}
    ) throws {
        guard path.components.isEmpty == false else {
            throw Self.contract("filesystem root is not a controlled directory")
        }
        let opened = try Self.openAbsolute(path)
        self.path = path
        descriptor = opened.descriptor
        identity = opened.identity
        do {
            try afterIdentityCapture()
            try validatePathBinding()
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func openExistingFile(
        named fileName: String,
        writable: Bool,
        afterOpen: () throws -> Void = {}
    ) throws -> DescriptorBoundFile {
        guard let file = try openExistingFileIfPresent(
            named: fileName,
            writable: writable,
            afterOpen: afterOpen
        ) else {
            throw Self.posixFailure(
                "open descriptor-bound file",
                code: ENOENT
            )
        }
        return file
    }

    func openExistingFileIfPresent(
        named fileName: String,
        writable: Bool,
        afterOpen: () throws -> Void = {}
    ) throws -> DescriptorBoundFile? {
        try CanonicalAbsolutePath.validate(component: fileName)
        try validatePathBinding()
        let flags = (writable ? O_RDWR : O_RDONLY)
            | O_NOFOLLOW
            | O_CLOEXEC
            | O_NONBLOCK
        let fileDescriptor = fileName.withCString {
            Darwin.openat(descriptor, $0, flags)
        }
        if fileDescriptor < 0, errno == ENOENT {
            try validatePathBinding()
            return nil
        }
        guard fileDescriptor >= 0 else {
            throw Self.posixFailure(
                "open descriptor-bound file",
                code: errno
            )
        }
        let file = try DescriptorBoundFile(
            descriptor: fileDescriptor,
            name: fileName,
            directory: self
        )
        try afterOpen()
        try validatePathBinding()
        return file
    }

    func createOrOpenFile(
        named fileName: String,
        mode: mode_t
    ) throws -> (file: DescriptorBoundFile, created: Bool) {
        try CanonicalAbsolutePath.validate(component: fileName)
        try validatePathBinding()
        var fileDescriptor = fileName.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                mode
            )
        }
        var created = true
        if fileDescriptor < 0, errno == EEXIST {
            created = false
            fileDescriptor = fileName.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
        }
        guard fileDescriptor >= 0 else {
            throw Self.posixFailure(
                "open or create descriptor-bound file",
                code: errno
            )
        }
        let file = try DescriptorBoundFile(
            descriptor: fileDescriptor,
            name: fileName,
            directory: self
        )
        try validatePathBinding()
        return (file: file, created: created)
    }

    func validatePathBinding() throws {
        let current = try Self.openAbsolute(path)
        defer { _ = Darwin.close(current.descriptor) }
        guard Self.sameDirectory(identity, current.identity) else {
            throw Self.contract("controlled directory path changed identity")
        }
        let openIdentity = try Self.fileIdentity(
            descriptor: descriptor,
            operation: "inspect pinned controlled directory"
        )
        guard Self.sameDirectory(identity, openIdentity) else {
            throw Self.contract("controlled directory descriptor changed identity")
        }
    }

    private static func openAbsolute(
        _ path: CanonicalAbsolutePath
    ) throws -> (descriptor: Int32, identity: stat) {
        let flags = O_RDONLY
            | O_DIRECTORY
            | O_NOFOLLOW
            | O_CLOEXEC
            | O_NONBLOCK
        var current = Darwin.open("/", flags)
        guard current >= 0 else {
            throw posixFailure("open filesystem root", code: errno)
        }
        do {
            for component in path.components {
                let next = component.withCString {
                    Darwin.openat(current, $0, flags)
                }
                guard next >= 0 else {
                    throw posixFailure(
                        "open controlled directory component",
                        code: errno
                    )
                }
                _ = Darwin.close(current)
                current = next
            }
            let status = try fileIdentity(
                descriptor: current,
                operation: "inspect controlled directory"
            )
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & (S_IWGRP | S_IWOTH) == 0
            else {
                throw contract(
                    "controlled directory is not owner-held and group/other-closed"
                )
            }
            return (descriptor: current, identity: status)
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    fileprivate static func fileIdentity(
        descriptor: Int32,
        operation: String
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixFailure(operation, code: errno)
        }
        return status
    }

    private static func sameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
    }

    static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }

    static func posixFailure(
        _ operation: String,
        code: Int32
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(
            "\(operation) failed: errno=\(code) "
                + String(cString: strerror(code))
        )
    }
}

final class DescriptorBoundFile {
    let descriptor: Int32
    let name: String
    private let directory: DescriptorBoundDirectory

    init(
        descriptor: Int32,
        name: String,
        directory: DescriptorBoundDirectory
    ) throws {
        self.descriptor = descriptor
        self.name = name
        self.directory = directory
        do {
            let status = try identity()
            guard status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1
            else {
                throw DescriptorBoundDirectory.contract(
                    "descriptor-bound file is not a singly-linked, owner-held regular file"
                )
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func identity() throws -> stat {
        try DescriptorBoundDirectory.fileIdentity(
            descriptor: descriptor,
            operation: "inspect descriptor-bound file"
        )
    }

    func validateNameStillBound(to expected: stat) throws {
        let rebound = try directory.openExistingFile(
            named: name,
            writable: false
        )
        let current = try rebound.identity()
        guard Self.sameObject(expected, current) else {
            throw DescriptorBoundDirectory.contract(
                "descriptor-bound file name changed identity"
            )
        }
    }

    static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
