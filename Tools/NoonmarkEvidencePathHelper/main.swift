import Darwin
import CryptoKit
import Foundation

@_silgen_name("kevent")
private func systemKevent(
    _ queueDescriptor: Int32,
    _ changes: UnsafePointer<kevent>?,
    _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?,
    _ eventCount: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

private enum EvidencePathHelperError: Error, CustomStringConvertible {
    case contract(String)
    case posix(String, Int32)

    var description: String {
        switch self {
        case let .contract(message):
            message
        case let .posix(operation, code):
            "\(operation) failed with errno \(code)"
        }
    }
}

private struct DescriptorIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
        kind = information.st_mode & S_IFMT
    }
}

private struct DirectoryBinding {
    let parentDescriptor: Int32
    let name: String
    let childDescriptor: Int32
    let identity: DescriptorIdentity
}

private final class BoundDirectoryChain {
    private(set) var descriptor: Int32
    private(set) var repositoryDevice: dev_t?
    private var descriptors: [Int32]
    private var bindings: [DirectoryBinding]
    private var repositoryDescriptor: Int32
    private var repositoryBindingCount: Int
    private let requiresRepositoryOwnership: Bool

    init(
        absolutePath: String,
        requireBoundaryOwnership: Bool = true
    ) throws {
        let components = try Self.absoluteComponents(absolutePath)
        let rootDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw Self.posixFailure("open repository filesystem root")
        }
        descriptor = rootDescriptor
        repositoryDevice = nil
        descriptors = [rootDescriptor]
        bindings = []
        repositoryDescriptor = -1
        repositoryBindingCount = 0
        requiresRepositoryOwnership = requireBoundaryOwnership

        do {
            for component in components {
                try openChildDirectory(
                    named: component,
                    createIfMissing: false
                )
            }
            let repositoryInformation = try Self.directoryInformation(
                descriptor: descriptor
            )
            guard requireBoundaryOwnership == false ||
                repositoryInformation.st_uid == geteuid()
            else {
                throw EvidencePathHelperError.contract(
                    "evidence repository must be owned by the current user"
                )
            }
            repositoryDevice = repositoryInformation.st_dev
            repositoryDescriptor = descriptor
            repositoryBindingCount = bindings.count
        } catch {
            closeDescriptors()
            throw error
        }
    }

    deinit {
        closeDescriptors()
    }

    func openChildDirectory(
        named name: String,
        createIfMissing: Bool
    ) throws {
        try Self.validateComponent(name)
        let parentDescriptor = descriptor
        var childDescriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if childDescriptor < 0, errno == ENOENT, createIfMissing {
            let creationResult = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o755))
            }
            if creationResult != 0, errno != EEXIST {
                throw Self.posixFailure("create evidence directory")
            }
            childDescriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard childDescriptor >= 0 else {
            throw Self.posixFailure("open evidence directory")
        }

        do {
            let identity = try Self.requireDirectory(
                descriptor: childDescriptor
            )
            if let repositoryDevice {
                try Self.requireOwnedDirectory(
                    descriptor: childDescriptor,
                    repositoryDevice: repositoryDevice
                )
            }
            let nameIdentity = try Self.entryIdentity(
                parentDescriptor: parentDescriptor,
                name: name
            )
            guard nameIdentity == identity else {
                throw EvidencePathHelperError.contract(
                    "evidence directory changed while it was opened"
                )
            }
            descriptor = childDescriptor
            descriptors.append(childDescriptor)
            bindings.append(
                DirectoryBinding(
                    parentDescriptor: parentDescriptor,
                    name: name,
                    childDescriptor: childDescriptor,
                    identity: identity
                )
            )
        } catch {
            Darwin.close(childDescriptor)
            throw error
        }
    }

    func validateBindings() throws {
        guard let repositoryDevice else {
            throw EvidencePathHelperError.contract(
                "evidence repository boundary is not initialized"
            )
        }
        if requiresRepositoryOwnership {
            try Self.requireOwnedDirectory(
                descriptor: repositoryDescriptor,
                repositoryDevice: repositoryDevice
            )
        } else {
            let information = try Self.directoryInformation(
                descriptor: repositoryDescriptor
            )
            guard information.st_dev == repositoryDevice else {
                throw EvidencePathHelperError.contract(
                    "evidence directory crosses a filesystem boundary"
                )
            }
        }
        for (index, binding) in bindings.enumerated() {
            let openedIdentity = try Self.requireDirectory(
                descriptor: binding.childDescriptor
            )
            let nameIdentity = try Self.entryIdentity(
                parentDescriptor: binding.parentDescriptor,
                name: binding.name
            )
            guard openedIdentity == binding.identity,
                  nameIdentity == binding.identity
            else {
                throw EvidencePathHelperError.contract(
                    "evidence directory binding changed"
                )
            }
            if index >= repositoryBindingCount {
                try Self.requireOwnedDirectory(
                    descriptor: binding.childDescriptor,
                    repositoryDevice: repositoryDevice
                )
            }
        }
    }

    private func closeDescriptors() {
        for descriptor in descriptors.reversed() {
            Darwin.close(descriptor)
        }
        descriptors.removeAll(keepingCapacity: false)
    }

    private static func absoluteComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path != "/",
              path.hasSuffix("/") == false,
              path.contains("//") == false,
              path.contains("\n") == false,
              path.contains("\r") == false,
              path.contains("\t") == false
        else {
            throw EvidencePathHelperError.contract(
                "repository root must be a canonical absolute path"
            )
        }
        let components = path.split(separator: "/").map(String.init)
        for component in components {
            try validateComponent(component)
        }
        guard "/" + components.joined(separator: "/") == path else {
            throw EvidencePathHelperError.contract(
                "repository root must be canonical"
            )
        }
        return components
    }

    static func relativeComponents(
        requestedPath: String,
        repositoryRoot: String
    ) throws -> [String] {
        guard requestedPath.isEmpty == false,
              requestedPath.hasSuffix("/") == false,
              requestedPath.contains("//") == false,
              requestedPath.contains("\n") == false,
              requestedPath.contains("\r") == false,
              requestedPath.contains("\t") == false
        else {
            throw EvidencePathHelperError.contract(
                "evidence path must be canonical"
            )
        }
        let relative: String
        if requestedPath.hasPrefix("/") {
            let prefix = repositoryRoot + "/"
            guard requestedPath.hasPrefix(prefix) else {
                throw EvidencePathHelperError.contract(
                    "evidence path escapes the repository"
                )
            }
            relative = String(requestedPath.dropFirst(prefix.count))
        } else {
            relative = requestedPath
        }
        let components = relative.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.isEmpty == false else {
            throw EvidencePathHelperError.contract(
                "evidence path cannot be the repository root"
            )
        }
        for component in components {
            try validateComponent(component)
        }
        guard components.joined(separator: "/") == relative else {
            throw EvidencePathHelperError.contract(
                "evidence path must be canonical"
            )
        }
        return components
    }

    static func validateComponent(_ component: String) throws {
        guard component.isEmpty == false,
              component != ".",
              component != "..",
              component.contains("/") == false,
              component.contains("\n") == false,
              component.contains("\r") == false,
              component.contains("\t") == false
        else {
            throw EvidencePathHelperError.contract(
                "evidence path contains an unsafe component"
            )
        }
    }

    static func requireDirectory(descriptor: Int32) throws
        -> DescriptorIdentity
    {
        let information = try directoryInformation(descriptor: descriptor)
        return DescriptorIdentity(information)
    }

    static func requireOwnedDirectory(
        descriptor: Int32,
        repositoryDevice: dev_t
    ) throws {
        let information = try directoryInformation(descriptor: descriptor)
        guard information.st_uid == geteuid() else {
            throw EvidencePathHelperError.contract(
                "evidence directory must be owned by the current user"
            )
        }
        guard information.st_dev == repositoryDevice else {
            throw EvidencePathHelperError.contract(
                "evidence directory crosses a filesystem boundary"
            )
        }
    }

    static func directoryInformation(descriptor: Int32) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixFailure("inspect opened evidence directory")
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw EvidencePathHelperError.contract(
                "opened evidence entry is not a directory"
            )
        }
        return information
    }

    static func entryIdentity(
        parentDescriptor: Int32,
        name: String
    ) throws -> DescriptorIdentity {
        var information = stat()
        let result = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            throw posixFailure("inspect evidence directory binding")
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw EvidencePathHelperError.contract(
                "evidence directory binding is not a directory"
            )
        }
        return DescriptorIdentity(information)
    }

    static func posixFailure(_ operation: String) -> EvidencePathHelperError {
        .posix(operation, errno)
    }
}

private struct FileSnapshot: Equatable {
    let identity: DescriptorIdentity
    let mode: mode_t
    let owner: uid_t
    let linkCount: nlink_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ information: stat) {
        identity = DescriptorIdentity(information)
        mode = information.st_mode
        owner = information.st_uid
        linkCount = information.st_nlink
        size = information.st_size
        modificationSeconds = information.st_mtimespec.tv_sec
        modificationNanoseconds = information.st_mtimespec.tv_nsec
        changeSeconds = information.st_ctimespec.tv_sec
        changeNanoseconds = information.st_ctimespec.tv_nsec
    }

    var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    var isRegularFile: Bool {
        mode & S_IFMT == S_IFREG
    }

    var isFIFO: Bool {
        mode & S_IFMT == S_IFIFO
    }

    func matchesContentAfterRename(_ other: FileSnapshot) -> Bool {
        identity == other.identity &&
            mode == other.mode &&
            owner == other.owner &&
            linkCount == other.linkCount &&
            size == other.size &&
            modificationSeconds == other.modificationSeconds &&
            modificationNanoseconds == other.modificationNanoseconds
    }

    func matchesObject(_ other: FileSnapshot) -> Bool {
        identity == other.identity &&
            mode == other.mode &&
            owner == other.owner &&
            linkCount == other.linkCount
    }
}

private func descriptorSnapshot(_ descriptor: Int32) throws -> FileSnapshot {
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
        throw EvidencePathHelperError.posix(
            "inspect evidence descriptor",
            errno
        )
    }
    return FileSnapshot(information)
}

private func entrySnapshot(
    parentDescriptor: Int32,
    name: String
) throws -> FileSnapshot? {
    var information = stat()
    let result = name.withCString {
        Darwin.fstatat(
            parentDescriptor,
            $0,
            &information,
            AT_SYMLINK_NOFOLLOW
        )
    }
    if result != 0, errno == ENOENT { return nil }
    guard result == 0 else {
        throw EvidencePathHelperError.posix(
            "inspect evidence entry",
            errno
        )
    }
    return FileSnapshot(information)
}

private func requireOwnedRegularFile(_ snapshot: FileSnapshot) throws {
    guard snapshot.isRegularFile,
          snapshot.owner == geteuid(),
          snapshot.linkCount == 1,
          snapshot.size >= 0
    else {
        throw EvidencePathHelperError.contract(
            "evidence input must be an owned single-link regular file"
        )
    }
}

private final class BootstrapContext {
    let commandArguments: [String]

    private let helperName = "NoonmarkEvidencePathHelper"

    init(arguments: [String]) throws {
        guard arguments.count >= 8,
              arguments[1] == "--bootstrap-parent-fd",
              arguments[3] == "--bootstrap-root-fd",
              arguments[5] == "--bootstrap-name",
              let parentDescriptor = Self.exactDescriptor(arguments[2]),
              let rootDescriptor = Self.exactDescriptor(arguments[4])
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper requires descriptor-bound bootstrap metadata"
            )
        }
        let rootName = arguments[6]
        try BoundDirectoryChain.validateComponent(rootName)
        guard rootName.hasPrefix("noonmark-evidence-path-helper."),
              rootName.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) ||
                      $0 == "." || $0 == "-"
              })
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper bootstrap name is invalid"
            )
        }

        let parentSnapshot = try descriptorSnapshot(parentDescriptor)
        let rootSnapshot = try descriptorSnapshot(rootDescriptor)
        guard parentSnapshot.isDirectory,
              rootSnapshot.isDirectory,
              rootSnapshot.owner == geteuid(),
              rootSnapshot.mode & mode_t(0o777) == mode_t(0o700),
              rootSnapshot.identity.device == parentSnapshot.identity.device
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper bootstrap descriptors are unsafe"
            )
        }
        guard let namedRoot = try entrySnapshot(
            parentDescriptor: parentDescriptor,
            name: rootName
        ), namedRoot.identity == rootSnapshot.identity,
            namedRoot.isDirectory
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper bootstrap root binding changed"
            )
        }
        guard let helperSnapshot = try entrySnapshot(
            parentDescriptor: rootDescriptor,
            name: helperName
        ) else {
            throw EvidencePathHelperError.contract(
                "evidence helper bootstrap binary is missing"
            )
        }
        try requireOwnedRegularFile(helperSnapshot)
        guard helperSnapshot.mode & mode_t(0o777) == mode_t(0o700) else {
            throw EvidencePathHelperError.contract(
                "evidence helper bootstrap binary mode is unsafe"
            )
        }

        commandArguments = [arguments[0]] + Array(arguments.dropFirst(7))
    }

    private static func exactDescriptor(_ value: String) -> Int32? {
        guard let descriptor = Int32(value), descriptor >= 3,
              String(descriptor) == value,
              fcntl(descriptor, F_GETFD) >= 0
        else { return nil }
        return descriptor
    }
}

private func requireRepositoryFile(
    _ snapshot: FileSnapshot,
    repositoryDevice: dev_t
) throws {
    try requireOwnedRegularFile(snapshot)
    guard snapshot.identity.device == repositoryDevice else {
        throw EvidencePathHelperError.contract(
            "evidence file crosses a filesystem boundary"
        )
    }
}

private let maximumFragmentBytes: off_t = 64 * 1024 * 1024

private struct AbsoluteFileLocation {
    let parentPath: String
    let name: String

    init(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/",
              path.hasSuffix("/") == false,
              path.contains("\n") == false,
              path.contains("\r") == false,
              path.contains("\t") == false
        else {
            throw EvidencePathHelperError.contract(
                "evidence file path must be a canonical absolute path"
            )
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            throw EvidencePathHelperError.contract(
                "evidence file parent cannot be the filesystem root"
            )
        }
        for component in components {
            try BoundDirectoryChain.validateComponent(component)
        }
        parentPath = "/" + components.dropLast().joined(separator: "/")
        name = components[components.count - 1]
    }
}

private func descriptorPhysicalPath(_ descriptor: Int32) throws -> String {
    var information = vnode_fdinfowithpath()
    let expectedSize = MemoryLayout<vnode_fdinfowithpath>.size
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        proc_pidfdinfo(
            getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            pointer,
            Int32(expectedSize)
        )
    }
    guard result == Int32(expectedSize) else {
        throw EvidencePathHelperError.posix(
            "resolve descriptor-bound evidence directory",
            errno
        )
    }
    var pathStorage = information.pvip.vip_path
    let path = withUnsafePointer(to: &pathStorage) { pointer in
        pointer.withMemoryRebound(
            to: CChar.self,
            capacity: Int(MAXPATHLEN)
        ) {
            String(cString: $0)
        }
    }
    guard path.hasPrefix("/"), path.hasSuffix("/") == false,
          path.contains("//") == false,
          path.contains("\n") == false,
          path.contains("\r") == false,
          path.contains("\t") == false
    else {
        throw EvidencePathHelperError.contract(
            "descriptor-bound evidence directory is not canonical"
        )
    }
    return path
}

private func bindPhysicalDirectory(
    logicalPath: String,
    requireOwnership: Bool = true
) throws -> BoundDirectoryChain {
    let openedDescriptor = logicalPath.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard openedDescriptor >= 0 else {
        throw EvidencePathHelperError.posix(
            "open evidence directory boundary",
            errno
        )
    }
    do {
        let openedIdentity = try BoundDirectoryChain.requireDirectory(
            descriptor: openedDescriptor
        )
        let physicalPath = try descriptorPhysicalPath(openedDescriptor)
        let chain = try BoundDirectoryChain(
            absolutePath: physicalPath,
            requireBoundaryOwnership: requireOwnership
        )
        let boundIdentity = try BoundDirectoryChain.requireDirectory(
            descriptor: chain.descriptor
        )
        guard openedIdentity == boundIdentity else {
            throw EvidencePathHelperError.contract(
                "evidence directory changed while establishing its boundary"
            )
        }
        Darwin.close(openedDescriptor)
        return chain
    } catch {
        Darwin.close(openedDescriptor)
        throw error
    }
}

private func readLimitedRegularFile(
    descriptor: Int32,
    captured: FileSnapshot,
    operation: String
) throws -> Data {
    try requireOwnedRegularFile(captured)
    guard captured.size <= maximumFragmentBytes else {
        throw EvidencePathHelperError.contract(
            "evidence fragment exceeds the 64 MiB input limit"
        )
    }
    guard try descriptorSnapshot(descriptor) == captured else {
        throw EvidencePathHelperError.contract(
            "\(operation) changed before reading"
        )
    }
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw EvidencePathHelperError.posix(
            "seek \(operation)",
            errno
        )
    }
    var data = Data()
    data.reserveCapacity(Int(captured.size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
            throw EvidencePathHelperError.posix(
                "read \(operation)",
                errno
            )
        }
        if count == 0 { break }
        guard data.count + count <= Int(maximumFragmentBytes) else {
            throw EvidencePathHelperError.contract(
                "evidence fragment exceeds the 64 MiB input limit"
            )
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    guard off_t(data.count) == captured.size,
          try descriptorSnapshot(descriptor) == captured
    else {
        throw EvidencePathHelperError.contract(
            "\(operation) changed while reading"
        )
    }
    return data
}

private final class BoundFileInput {
    private let chain: BoundDirectoryChain
    private let name: String
    private let descriptor: Int32
    private let captured: FileSnapshot

    init(path: String) throws {
        let location = try AbsoluteFileLocation(path)
        let chain = try bindPhysicalDirectory(
            logicalPath: location.parentPath
        )
        guard let repositoryDevice = chain.repositoryDevice,
              let captured = try entrySnapshot(
                  parentDescriptor: chain.descriptor,
                  name: location.name
              )
        else {
            throw EvidencePathHelperError.contract(
                "evidence fragment input is missing"
            )
        }
        try requireRepositoryFile(
            captured,
            repositoryDevice: repositoryDevice
        )
        guard captured.size <= maximumFragmentBytes else {
            throw EvidencePathHelperError.contract(
                "evidence fragment exceeds the 64 MiB input limit"
            )
        }
        let descriptor = location.name.withCString {
            Darwin.openat(
                chain.descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw EvidencePathHelperError.posix(
                "open evidence fragment input",
                errno
            )
        }
        do {
            guard try descriptorSnapshot(descriptor) == captured else {
                throw EvidencePathHelperError.contract(
                    "evidence fragment changed while opening"
                )
            }
            self.chain = chain
            name = location.name
            self.descriptor = descriptor
            self.captured = captured
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func validateBinding() throws {
        try chain.validateBindings()
        guard try descriptorSnapshot(descriptor) == captured,
              try entrySnapshot(
                  parentDescriptor: chain.descriptor,
                  name: name
              ) == captured
        else {
            throw EvidencePathHelperError.contract(
                "evidence fragment input binding changed"
            )
        }
    }

    func readData() throws -> Data {
        try validateBinding()
        let data = try readLimitedRegularFile(
            descriptor: descriptor,
            captured: captured,
            operation: "evidence fragment input"
        )
        try validateBinding()
        return data
    }
}

private final class BoundAtomicDestination {
    private let chain: BoundDirectoryChain
    private let name: String
    private let existingDescriptor: Int32?
    private let existingSnapshot: FileSnapshot?

    init(path: String) throws {
        let location = try AbsoluteFileLocation(path)
        let boundChain = try bindPhysicalDirectory(
            logicalPath: location.parentPath
        )

        guard let repositoryDevice = boundChain.repositoryDevice else {
            throw EvidencePathHelperError.contract(
                "evidence destination filesystem boundary is missing"
            )
        }
        let captured = try entrySnapshot(
            parentDescriptor: boundChain.descriptor,
            name: location.name
        )
        var openedDescriptor: Int32?
        if let captured {
            try requireRepositoryFile(
                captured,
                repositoryDevice: repositoryDevice
            )
            let descriptor = location.name.withCString {
                Darwin.openat(
                    boundChain.descriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw EvidencePathHelperError.posix(
                    "open existing evidence destination",
                    errno
                )
            }
            do {
                let opened = try descriptorSnapshot(descriptor)
                guard opened == captured else {
                    throw EvidencePathHelperError.contract(
                        "evidence destination changed while opening"
                    )
                }
                openedDescriptor = descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        chain = boundChain
        name = location.name
        existingDescriptor = openedDescriptor
        existingSnapshot = captured
    }

    deinit {
        if let existingDescriptor {
            Darwin.close(existingDescriptor)
        }
    }

    var exists: Bool {
        existingSnapshot != nil
    }

    func validateBinding() throws {
        try chain.validateBindings()
        let current = try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: name
        )
        if let existingDescriptor, let existingSnapshot {
            guard try descriptorSnapshot(existingDescriptor)
                == existingSnapshot,
                current == existingSnapshot
            else {
                throw EvidencePathHelperError.contract(
                    "evidence destination binding changed"
                )
            }
        } else if current != nil {
            throw EvidencePathHelperError.contract(
                "evidence destination appeared after binding"
            )
        }
    }

    func readExistingData() throws -> Data {
        guard let existingDescriptor, let existingSnapshot else {
            throw EvidencePathHelperError.contract(
                "manifest append requires an existing destination"
            )
        }
        try validateBinding()
        let data = try readLimitedRegularFile(
            descriptor: existingDescriptor,
            captured: existingSnapshot,
            operation: "evidence destination"
        )
        try validateBinding()
        return data
    }

    func publish(_ data: Data) throws {
        guard data.count <= Int(maximumFragmentBytes) else {
            throw EvidencePathHelperError.contract(
                "evidence output exceeds the 64 MiB limit"
            )
        }
        try validateBinding()
        let stagedName = ".noonmark-fragment-\(UUID().uuidString)"
        let stagedDescriptor = stagedName.withCString {
            Darwin.openat(
                chain.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard stagedDescriptor >= 0 else {
            throw EvidencePathHelperError.posix(
                "create staged evidence fragment",
                errno
            )
        }
        var removeStage = true
        defer {
            if removeStage,
               let opened = try? descriptorSnapshot(stagedDescriptor),
               let current = try? entrySnapshot(
                   parentDescriptor: chain.descriptor,
                   name: stagedName
               ), current.identity == opened.identity
            {
                _ = stagedName.withCString {
                    Darwin.unlinkat(chain.descriptor, $0, 0)
                }
            }
            Darwin.close(stagedDescriptor)
        }

        try writeAll(data, to: stagedDescriptor)
        guard fsync(stagedDescriptor) == 0 else {
            throw EvidencePathHelperError.posix(
                "synchronize staged evidence fragment",
                errno
            )
        }
        let stagedSnapshot = try descriptorSnapshot(stagedDescriptor)
        guard let repositoryDevice = chain.repositoryDevice else {
            throw EvidencePathHelperError.contract(
                "evidence destination filesystem boundary is missing"
            )
        }
        try requireRepositoryFile(
            stagedSnapshot,
            repositoryDevice: repositoryDevice
        )
        try validateBinding()

        if let existingSnapshot {
            let swapResult = stagedName.withCString { staged in
                name.withCString { destination in
                    Darwin.renameatx_np(
                        chain.descriptor,
                        staged,
                        chain.descriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "atomically exchange evidence destination",
                    errno
                )
            }
            let published = try entrySnapshot(
                parentDescriptor: chain.descriptor,
                name: name
            )
            let exchanged = try entrySnapshot(
                parentDescriptor: chain.descriptor,
                name: stagedName
            )
            let openedPrevious = try existingDescriptor.map {
                try descriptorSnapshot($0)
            }
            guard published?.identity == stagedSnapshot.identity,
                  published?.size == stagedSnapshot.size,
                  exchanged?.matchesContentAfterRename(existingSnapshot)
                    == true,
                  openedPrevious?.matchesContentAfterRename(existingSnapshot)
                    == true
            else {
                throw EvidencePathHelperError.contract(
                    "atomic evidence destination exchange changed an inode"
                )
            }
            let unlinkPreviousResult = stagedName.withCString {
                Darwin.unlinkat(chain.descriptor, $0, 0)
            }
            guard unlinkPreviousResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "remove exchanged evidence destination",
                    errno
                )
            }
            removeStage = false
        } else {
            let publishResult = stagedName.withCString { source in
                name.withCString { destination in
                    Darwin.linkat(
                        chain.descriptor,
                        source,
                        chain.descriptor,
                        destination,
                        0
                    )
                }
            }
            guard publishResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "publish evidence fragment",
                    errno
                )
            }
            let published = try entrySnapshot(
                parentDescriptor: chain.descriptor,
                name: name
            )
            guard published?.identity == stagedSnapshot.identity,
                  published?.size == stagedSnapshot.size,
                  published?.owner == geteuid()
            else {
                throw EvidencePathHelperError.contract(
                    "published evidence fragment changed"
                )
            }
            let unlinkStageResult = stagedName.withCString {
                Darwin.unlinkat(chain.descriptor, $0, 0)
            }
            guard unlinkStageResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "remove staged evidence fragment name",
                    errno
                )
            }
            removeStage = false
        }
        let finalPublished = try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: name
        )
        guard finalPublished?.identity == stagedSnapshot.identity,
              finalPublished?.size == stagedSnapshot.size,
              finalPublished?.owner == geteuid()
        else {
            throw EvidencePathHelperError.contract(
                "published evidence fragment changed after cutover"
            )
        }
        guard fsync(chain.descriptor) == 0 else {
            throw EvidencePathHelperError.posix(
                "synchronize evidence destination directory",
                errno
            )
        }
        try chain.validateBindings()
    }
}

private func validateManifestAppend(
    existing: Data,
    addition: Data
) throws {
    guard let existingText = String(data: existing, encoding: .utf8),
          let additionText = String(data: addition, encoding: .utf8),
          existingText.hasSuffix("\n"),
          additionText.hasSuffix("\n")
    else {
        throw EvidencePathHelperError.contract(
            "manifest append requires newline-terminated UTF-8"
        )
    }
    var keys = Set<String>()
    for text in [existingText, additionText] {
        guard text.contains("\r") == false else {
            throw EvidencePathHelperError.contract(
                "manifest append contains a carriage return"
            )
        }
        let body = text.dropLast()
        guard body.isEmpty == false else {
            throw EvidencePathHelperError.contract(
                "manifest append contains no rows"
            )
        }
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        for line in lines {
            guard line.isEmpty == false,
                  let separator = line.firstIndex(of: "="),
                  separator != line.startIndex
            else {
                throw EvidencePathHelperError.contract(
                    "manifest append contains an invalid row"
                )
            }
            let key = String(line[..<separator])
            let valueStart = line.index(after: separator)
            guard valueStart != line.endIndex,
                  key.first?.isASCII == true,
                  key.first?.isLetter == true,
                  key.allSatisfy({
                      $0.isASCII &&
                          ($0.isLetter || $0.isNumber || $0 == "_")
                  }),
                  keys.insert(key).inserted
            else {
                throw EvidencePathHelperError.contract(
                    "manifest append contains an invalid or duplicate key"
                )
            }
        }
    }
}

private func replaceFragment(
    destinationPath: String,
    sourcePath: String
) throws {
    let input = try BoundFileInput(path: sourcePath)
    let destination = try BoundAtomicDestination(path: destinationPath)
    try TestInterposition.pauseIfRequested()
    try input.validateBinding()
    try destination.validateBinding()
    let data = try input.readData()
    try destination.validateBinding()
    try destination.publish(data)
}

private func appendManifest(
    destinationPath: String,
    additionPath: String
) throws {
    let input = try BoundFileInput(path: additionPath)
    let destination = try BoundAtomicDestination(path: destinationPath)
    guard destination.exists else {
        throw EvidencePathHelperError.contract(
            "manifest append destination is missing"
        )
    }
    try TestInterposition.pauseIfRequested()
    try input.validateBinding()
    try destination.validateBinding()
    let existing = try destination.readExistingData()
    let addition = try input.readData()
    try validateManifestAppend(existing: existing, addition: addition)
    guard existing.count + addition.count <= Int(maximumFragmentBytes) else {
        throw EvidencePathHelperError.contract(
            "manifest append exceeds the 64 MiB output limit"
        )
    }
    try destination.validateBinding()
    var combined = existing
    combined.append(addition)
    try destination.publish(combined)
}

private final class BoundSessionTransport {
    static let requestName = "request.fifo"
    static let responseName = "response.fifo"
    static let lockName = "lock.fifo"

    private let parentChain: BoundDirectoryChain
    private let parentDescriptor: Int32
    private let rootDescriptor: Int32
    private let rootName: String
    private let rootIdentity: DescriptorIdentity
    private let fifoSnapshots: [String: FileSnapshot]

    init(path: String) throws {
        let location = try AbsoluteFileLocation(path)
        let parentChain = try bindPhysicalDirectory(
            logicalPath: location.parentPath,
            requireOwnership: false
        )
        guard let repositoryDevice = parentChain.repositoryDevice,
              let capturedRoot = try entrySnapshot(
                  parentDescriptor: parentChain.descriptor,
                  name: location.name
              ), capturedRoot.isDirectory,
              capturedRoot.owner == geteuid(),
              capturedRoot.identity.device == repositoryDevice,
              capturedRoot.mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper session transport is unsafe"
            )
        }
        let rootDescriptor = location.name.withCString {
            Darwin.openat(
                parentChain.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            throw EvidencePathHelperError.posix(
                "open evidence helper session transport",
                errno
            )
        }
        do {
            let openedRoot = try descriptorSnapshot(rootDescriptor)
            guard openedRoot == capturedRoot else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session transport changed while opening"
                )
            }
            let expectedNames = [
                Self.lockName,
                Self.requestName,
                Self.responseName,
            ]
            guard try directoryEntryNames(rootDescriptor).sorted()
                == expectedNames
            else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session transport has unexpected entries"
                )
            }
            var snapshots: [String: FileSnapshot] = [:]
            for name in expectedNames {
                guard let snapshot = try entrySnapshot(
                    parentDescriptor: rootDescriptor,
                    name: name
                ), snapshot.isFIFO,
                    snapshot.owner == geteuid(),
                    snapshot.linkCount == 1,
                    snapshot.identity.device == repositoryDevice
                else {
                    throw EvidencePathHelperError.contract(
                        "evidence helper session transport FIFO is unsafe"
                    )
                }
                snapshots[name] = snapshot
            }
            self.parentChain = parentChain
            parentDescriptor = parentChain.descriptor
            self.rootDescriptor = rootDescriptor
            rootName = location.name
            rootIdentity = capturedRoot.identity
            fifoSnapshots = snapshots
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    func cleanup() throws {
        guard try descriptorSnapshot(rootDescriptor).identity == rootIdentity else {
            throw EvidencePathHelperError.contract(
                "evidence helper session transport descriptor changed"
            )
        }
        for name in [Self.requestName, Self.responseName, Self.lockName] {
            guard let captured = fifoSnapshots[name],
                  try entrySnapshot(
                      parentDescriptor: rootDescriptor,
                      name: name
                  )?.matchesObject(captured) == true
            else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session FIFO binding changed"
                )
            }
        }
        for name in [Self.requestName, Self.responseName, Self.lockName] {
            let result = name.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw EvidencePathHelperError.posix(
                    "remove evidence helper session FIFO",
                    errno
                )
            }
        }
        try parentChain.validateBindings()
        guard try directoryEntryNames(rootDescriptor).isEmpty,
              try entrySnapshot(
                  parentDescriptor: parentDescriptor,
                  name: rootName
              )?.identity == rootIdentity
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper session transport changed before removal"
            )
        }
        let result = rootName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw EvidencePathHelperError.posix(
                "remove evidence helper session transport",
                errno
            )
        }
    }
}

private final class SessionCallerLiveness {
    enum WaitResult: Equatable {
        case readable
        case callerExited
    }

    private let queueDescriptor: Int32

    init(callerPID: pid_t) throws {
        guard callerPID > 1,
              kill(callerPID, 0) == 0 || errno == EPERM
        else {
            throw EvidencePathHelperError.contract(
                "evidence helper session caller is not alive"
            )
        }
        let queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            throw EvidencePathHelperError.posix(
                "create evidence helper session kqueue",
                errno
            )
        }
        var changes = [kevent(), kevent()]
        changes[0].ident = UInt(callerPID)
        changes[0].filter = Int16(EVFILT_PROC)
        changes[0].flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        changes[0].fflags = UInt32(NOTE_EXIT)
        changes[1].ident = UInt(STDIN_FILENO)
        changes[1].filter = Int16(EVFILT_READ)
        changes[1].flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        let registration = changes.withUnsafeBufferPointer { pointer in
            systemKevent(
                queueDescriptor,
                pointer.baseAddress,
                Int32(pointer.count),
                nil,
                0,
                nil
            )
        }
        guard registration == 0 else {
            let code = errno
            Darwin.close(queueDescriptor)
            throw EvidencePathHelperError.posix(
                "register evidence helper session liveness",
                code
            )
        }
        self.queueDescriptor = queueDescriptor
    }

    deinit {
        Darwin.close(queueDescriptor)
    }

    func waitForInput() throws -> WaitResult {
        var events = [kevent(), kevent()]
        var count: Int32
        repeat {
            count = events.withUnsafeMutableBufferPointer { pointer in
                systemKevent(
                    queueDescriptor,
                    nil,
                    0,
                    pointer.baseAddress,
                    Int32(pointer.count),
                    nil
                )
            }
        } while count < 0 && errno == EINTR
        guard count > 0 else {
            throw EvidencePathHelperError.posix(
                "wait for evidence helper session input",
                errno
            )
        }
        let received = events.prefix(Int(count))
        if received.contains(where: {
            $0.filter == Int16(EVFILT_PROC)
        }) {
            return .callerExited
        }
        guard received.contains(where: {
            $0.filter == Int16(EVFILT_READ)
        }) else {
            throw EvidencePathHelperError.contract(
                "evidence helper session received an unknown event"
            )
        }
        return .readable
    }
}

private final class SessionProtocolReader {
    private var buffered = Data()
    private let liveness: SessionCallerLiveness

    init(liveness: SessionCallerLiveness) {
        self.liveness = liveness
    }

    func readLine() throws -> String? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let lineData = buffered[..<newline]
                buffered.removeSubrange(...newline)
                guard lineData.count <= 16 * 1024,
                      let line = String(data: lineData, encoding: .utf8),
                      line.contains("\r") == false
                else {
                    throw EvidencePathHelperError.contract(
                        "evidence helper session line is invalid"
                    )
                }
                return line
            }
            guard buffered.count <= 16 * 1024 else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session line is too long"
                )
            }
            if try liveness.waitForInput() == .callerExited {
                guard buffered.isEmpty else {
                    throw EvidencePathHelperError.contract(
                        "evidence helper caller exited with a partial line"
                    )
                }
                return nil
            }
            var bytes = [UInt8](repeating: 0, count: 4 * 1024)
            let count = bytes.withUnsafeMutableBytes { pointer in
                Darwin.read(STDIN_FILENO, pointer.baseAddress, pointer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw EvidencePathHelperError.posix(
                    "read evidence helper session request",
                    errno
                )
            }
            if count == 0 {
                guard buffered.isEmpty else {
                    throw EvidencePathHelperError.contract(
                        "evidence helper session ended with a partial line"
                    )
                }
                return nil
            }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }

    func readData(count: Int) throws -> Data {
        guard count >= 0, count <= Int(maximumFragmentBytes) else {
            throw EvidencePathHelperError.contract(
                "evidence helper session payload is too large"
            )
        }
        var data = Data()
        data.reserveCapacity(count)
        if buffered.isEmpty == false {
            let copied = min(count, buffered.count)
            data.append(buffered.prefix(copied))
            buffered.removeFirst(copied)
        }
        while data.count < count {
            guard try liveness.waitForInput() == .readable else {
                throw EvidencePathHelperError.contract(
                    "evidence helper caller exited during a payload"
                )
            }
            var bytes = [UInt8](
                repeating: 0,
                count: min(64 * 1024, count - data.count)
            )
            let received = bytes.withUnsafeMutableBytes { pointer in
                Darwin.read(STDIN_FILENO, pointer.baseAddress, pointer.count)
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                if received == 0 {
                    throw EvidencePathHelperError.contract(
                        "evidence helper session payload ended early"
                    )
                }
                throw EvidencePathHelperError.posix(
                    "read evidence helper session payload",
                    errno
                )
            }
            data.append(contentsOf: bytes.prefix(received))
        }
        return data
    }
}

private func exactNonnegativeInteger(
    _ value: String,
    maximum: Int
) -> Int? {
    guard let number = Int(value), number >= 0, number <= maximum,
          String(number) == value
    else { return nil }
    return number
}

private enum PreparedSessionRequest {
    case deferred(String, [String], Data)
    case replace(BoundFileInput, BoundAtomicDestination)
    case appendManifest(BoundFileInput, BoundAtomicDestination)

    func execute() throws {
        switch self {
        case let .deferred(command, arguments, payload):
            try executeSessionRequest(
                command: command,
                arguments: arguments,
                payload: payload
            )
        case let .replace(input, destination):
            try input.validateBinding()
            try destination.validateBinding()
            let data = try input.readData()
            try destination.validateBinding()
            try destination.publish(data)
        case let .appendManifest(input, destination):
            try input.validateBinding()
            try destination.validateBinding()
            let existing = try destination.readExistingData()
            let addition = try input.readData()
            try validateManifestAppend(
                existing: existing,
                addition: addition
            )
            guard existing.count + addition.count
                <= Int(maximumFragmentBytes)
            else {
                throw EvidencePathHelperError.contract(
                    "manifest append exceeds the 64 MiB output limit"
                )
            }
            try destination.validateBinding()
            var combined = existing
            combined.append(addition)
            try destination.publish(combined)
        }
    }
}

private func prepareSessionRequest(
    command: String,
    arguments: [String],
    payload: Data
) throws -> PreparedSessionRequest {
    switch command {
    case "replace-path":
        guard arguments.count == 2, payload.isEmpty else {
            throw EvidencePathHelperError.contract(
                "session replace request is invalid"
            )
        }
        return try .replace(
            BoundFileInput(path: arguments[1]),
            BoundAtomicDestination(path: arguments[0])
        )
    case "append-manifest-path":
        guard arguments.count == 2, payload.isEmpty else {
            throw EvidencePathHelperError.contract(
                "session manifest append request is invalid"
            )
        }
        let input = try BoundFileInput(path: arguments[1])
        let destination = try BoundAtomicDestination(path: arguments[0])
        guard destination.exists else {
            throw EvidencePathHelperError.contract(
                "manifest append destination is missing"
            )
        }
        return .appendManifest(input, destination)
    default:
        return .deferred(command, arguments, payload)
    }
}

private func executeSessionRequest(
    command: String,
    arguments: [String],
    payload: Data
) throws {
    switch command {
    case "ping":
        guard arguments.isEmpty, payload.isEmpty else {
            throw EvidencePathHelperError.contract(
                "session ping request is invalid"
            )
        }
    case "prepare":
        guard arguments.count == 2, payload.isEmpty else {
            throw EvidencePathHelperError.contract(
                "session prepare request is invalid"
            )
        }
        try prepareFreshDirectory(
            repositoryRoot: arguments[0],
            requestedPath: arguments[1]
        )
    case "inventory":
        guard arguments.count >= 3, payload.isEmpty else {
            throw EvidencePathHelperError.contract(
                "session inventory request is invalid"
            )
        }
        try captureInventory(
            repositoryRoot: arguments[0],
            outputPath: arguments[1],
            candidatePaths: Array(arguments.dropFirst(2))
        )
    default:
        throw EvidencePathHelperError.contract(
            "evidence helper session command is unknown"
        )
    }
}

private func serveSession(
    transportPath: String,
    callerPID: pid_t
) throws {
    let transport = try BoundSessionTransport(path: transportPath)
    let liveness = try SessionCallerLiveness(callerPID: callerPID)
    let reader = SessionProtocolReader(liveness: liveness)
    var serverError: Error?
    do {
        while let header = try reader.readLine() {
            let fields = header.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 4, fields[0] == "NM1",
                  let argumentCount = exactNonnegativeInteger(
                      fields[2],
                      maximum: 1024
                  ),
                  let payloadSize = exactNonnegativeInteger(
                      fields[3],
                      maximum: Int(maximumFragmentBytes)
                  )
            else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session header is invalid"
                )
            }
            var arguments: [String] = []
            arguments.reserveCapacity(argumentCount)
            for _ in 0..<argumentCount {
                guard let argument = try reader.readLine(),
                      argument.contains("\t") == false,
                      argument.isEmpty == false
                else {
                    throw EvidencePathHelperError.contract(
                        "evidence helper session argument is invalid"
                    )
                }
                arguments.append(argument)
            }
            let payload = try reader.readData(count: payloadSize)
            let prepared: PreparedSessionRequest
            do {
                prepared = try prepareSessionRequest(
                    command: fields[1],
                    arguments: arguments,
                    payload: payload
                )
            } catch {
                fputs("Noonmark evidence session request: \(error)\n", stderr)
                try writeAll(Data("E\n".utf8), to: STDOUT_FILENO)
                continue
            }
            try writeAll(Data("P\n".utf8), to: STDOUT_FILENO)
            guard let decision = try reader.readLine() else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session commit decision is missing"
                )
            }
            if decision == "A" {
                try writeAll(Data("1\n".utf8), to: STDOUT_FILENO)
                continue
            }
            guard decision == "G" else {
                throw EvidencePathHelperError.contract(
                    "evidence helper session commit decision is invalid"
                )
            }
            do {
                try prepared.execute()
                try writeAll(Data("0\n".utf8), to: STDOUT_FILENO)
            } catch {
                fputs("Noonmark evidence session request: \(error)\n", stderr)
                try writeAll(Data("1\n".utf8), to: STDOUT_FILENO)
            }
        }
    } catch {
        serverError = error
    }
    var cleanupError: Error?
    do {
        try transport.cleanup()
    } catch {
        cleanupError = error
    }
    if let serverError { throw serverError }
    if let cleanupError { throw cleanupError }
}

private final class BoundInventoryCandidate {
    enum Kind {
        case directory(Int32, FileSnapshot)
        case file(Int32, FileSnapshot)
    }

    let relativePath: String
    let kind: Kind
    private let chain: BoundDirectoryChain
    private let entryName: String?

    var repositoryDevice: dev_t {
        guard let repositoryDevice = chain.repositoryDevice else {
            fatalError("bound inventory candidate has no repository device")
        }
        return repositoryDevice
    }

    init(repositoryRoot: String, requestedPath: String) throws {
        let components = try BoundDirectoryChain.relativeComponents(
            requestedPath: requestedPath,
            repositoryRoot: repositoryRoot
        )
        let candidateRelativePath = components.joined(separator: "/")
        let boundChain = try BoundDirectoryChain(absolutePath: repositoryRoot)
        for component in components.dropLast() {
            try boundChain.openChildDirectory(
                named: component,
                createIfMissing: false
            )
        }

        let name = components[components.count - 1]
        guard let captured = try entrySnapshot(
            parentDescriptor: boundChain.descriptor,
            name: name
        ) else {
            throw EvidencePathHelperError.contract(
                "artifact inventory input is missing"
            )
        }
        if captured.isDirectory {
            guard captured.owner == geteuid() else {
                throw EvidencePathHelperError.contract(
                    "artifact inventory directory has the wrong owner"
                )
            }
            try boundChain.openChildDirectory(
                named: name,
                createIfMissing: false
            )
            let opened = try descriptorSnapshot(boundChain.descriptor)
            guard opened == captured else {
                throw EvidencePathHelperError.contract(
                    "artifact inventory directory changed while opening"
                )
            }
            chain = boundChain
            entryName = nil
            kind = .directory(boundChain.descriptor, opened)
        } else {
            guard let repositoryDevice = boundChain.repositoryDevice else {
                throw EvidencePathHelperError.contract(
                    "artifact inventory repository boundary is missing"
                )
            }
            try requireRepositoryFile(
                captured,
                repositoryDevice: repositoryDevice
            )
            let descriptor = name.withCString {
                Darwin.openat(
                    boundChain.descriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw EvidencePathHelperError.posix(
                    "open artifact inventory input",
                    errno
                )
            }
            do {
                let opened = try descriptorSnapshot(descriptor)
                try requireRepositoryFile(
                    opened,
                    repositoryDevice: repositoryDevice
                )
                guard opened == captured else {
                    throw EvidencePathHelperError.contract(
                        "artifact inventory input changed while opening"
                    )
                }
                chain = boundChain
                entryName = name
                kind = .file(descriptor, opened)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        relativePath = candidateRelativePath
    }

    deinit {
        if case let .file(descriptor, _) = kind {
            Darwin.close(descriptor)
        }
    }

    func validateBinding() throws {
        try chain.validateBindings()
        if case let .directory(descriptor, captured) = kind {
            let opened = try descriptorSnapshot(descriptor)
            guard opened == captured else {
                throw EvidencePathHelperError.contract(
                    "artifact inventory directory changed"
                )
            }
            return
        }
        guard let entryName else {
            throw EvidencePathHelperError.contract(
                "artifact inventory file binding is incomplete"
            )
        }
        guard case let .file(descriptor, captured) = kind else {
            throw EvidencePathHelperError.contract(
                "artifact inventory candidate binding is invalid"
            )
        }
        let opened = try descriptorSnapshot(descriptor)
        let current = try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: entryName
        )
        guard opened == captured, current == captured else {
            throw EvidencePathHelperError.contract(
                "artifact inventory input binding changed"
            )
        }
    }
}

private final class BoundInventoryOutput {
    private let chain: BoundDirectoryChain
    private let name: String

    let relativePath: String

    init(repositoryRoot: String, requestedPath: String) throws {
        let components = try BoundDirectoryChain.relativeComponents(
            requestedPath: requestedPath,
            repositoryRoot: repositoryRoot
        )
        relativePath = components.joined(separator: "/")
        chain = try BoundDirectoryChain(absolutePath: repositoryRoot)
        for component in components.dropLast() {
            try chain.openChildDirectory(
                named: component,
                createIfMissing: true
            )
        }
        name = components[components.count - 1]
        if try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: name
        ) != nil {
            throw EvidencePathHelperError.contract(
                "artifact inventory output must not already exist"
            )
        }
    }

    func validateBinding() throws {
        try chain.validateBindings()
        let current = try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: name
        )
        if current != nil {
            throw EvidencePathHelperError.contract(
                "artifact inventory output appeared during capture"
            )
        }
    }

    func publish(_ data: Data) throws {
        try validateBinding()
        let stagedName = ".noonmark-inventory-\(UUID().uuidString)"
        let stagedDescriptor = stagedName.withCString {
            Darwin.openat(
                chain.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard stagedDescriptor >= 0 else {
            throw EvidencePathHelperError.posix(
                "create staged artifact inventory",
                errno
            )
        }
        var shouldRemoveStage = true
        defer {
            Darwin.close(stagedDescriptor)
            if shouldRemoveStage {
                _ = stagedName.withCString {
                    Darwin.unlinkat(chain.descriptor, $0, 0)
                }
            }
        }

        try writeAll(data, to: stagedDescriptor)
        guard fsync(stagedDescriptor) == 0 else {
            throw EvidencePathHelperError.posix(
                "synchronize staged artifact inventory",
                errno
            )
        }
        let stagedSnapshot = try descriptorSnapshot(stagedDescriptor)
        try requireOwnedRegularFile(stagedSnapshot)
        try validateBinding()
        let linkResult = stagedName.withCString { source in
            name.withCString { destination in
                Darwin.linkat(
                    chain.descriptor,
                    source,
                    chain.descriptor,
                    destination,
                    0
                )
            }
        }
        guard linkResult == 0 else {
            throw EvidencePathHelperError.posix(
                "publish artifact inventory",
                errno
            )
        }
        let unlinkResult = stagedName.withCString {
            Darwin.unlinkat(chain.descriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            throw EvidencePathHelperError.posix(
                "remove staged artifact inventory name",
                errno
            )
        }
        shouldRemoveStage = false
        let published = try entrySnapshot(
            parentDescriptor: chain.descriptor,
            name: name
        )
        guard let published else {
            throw EvidencePathHelperError.contract(
                "published artifact inventory is missing"
            )
        }
        try requireOwnedRegularFile(published)
        guard published.identity == stagedSnapshot.identity,
              published.size == stagedSnapshot.size
        else {
            throw EvidencePathHelperError.contract(
                "published artifact inventory changed"
            )
        }
        try chain.validateBindings()
    }
}

private struct InventoryRow {
    let digest: String
    let size: off_t
    let relativePath: String
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw EvidencePathHelperError.posix(
                    "write evidence data",
                    errno
                )
            }
            offset += count
        }
    }
}

private func requireRepositoryDirectory(
    _ snapshot: FileSnapshot,
    repositoryDevice: dev_t
) throws {
    guard snapshot.isDirectory,
          snapshot.owner == geteuid()
    else {
        throw EvidencePathHelperError.contract(
            "artifact inventory directory must be owned by the current user"
        )
    }
    guard snapshot.identity.device == repositoryDevice else {
        throw EvidencePathHelperError.contract(
            "artifact inventory directory crosses a filesystem boundary"
        )
    }
}

private func inventoryRowForRegularFile(
    descriptor: Int32,
    captured: FileSnapshot,
    parentDescriptor: Int32?,
    name: String?,
    relativePath: String,
    repositoryDevice: dev_t
) throws -> InventoryRow {
    try requireRepositoryFile(
        captured,
        repositoryDevice: repositoryDevice
    )
    let before = try descriptorSnapshot(descriptor)
    guard before == captured else {
        throw EvidencePathHelperError.contract(
            "artifact inventory file changed before hashing"
        )
    }
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw EvidencePathHelperError.posix(
            "seek artifact inventory input",
            errno
        )
    }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var totalSize: off_t = 0
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
            throw EvidencePathHelperError.posix(
                "read artifact inventory input",
                errno
            )
        }
        if count == 0 { break }
        totalSize += off_t(count)
        hasher.update(data: Data(buffer.prefix(count)))
    }
    guard totalSize == captured.size else {
        throw EvidencePathHelperError.contract(
            "artifact inventory file size changed while hashing"
        )
    }

    let after = try descriptorSnapshot(descriptor)
    guard after == captured else {
        throw EvidencePathHelperError.contract(
            "artifact inventory file changed while hashing"
        )
    }
    if let parentDescriptor, let name {
        let current = try entrySnapshot(
            parentDescriptor: parentDescriptor,
            name: name
        )
        guard current == captured else {
            throw EvidencePathHelperError.contract(
                "artifact inventory file binding changed while hashing"
            )
        }
    } else if parentDescriptor != nil || name != nil {
        throw EvidencePathHelperError.contract(
            "artifact inventory file binding is incomplete"
        )
    }

    let digest = hasher.finalize().map {
        String(format: "%02x", $0)
    }.joined()
    return InventoryRow(
        digest: digest,
        size: totalSize,
        relativePath: relativePath
    )
}

private func inventoryRows(
    directoryDescriptor: Int32,
    captured: FileSnapshot,
    relativePath: String,
    repositoryDevice: dev_t
) throws -> [InventoryRow] {
    try requireRepositoryDirectory(
        captured,
        repositoryDevice: repositoryDevice
    )
    guard try descriptorSnapshot(directoryDescriptor) == captured else {
        throw EvidencePathHelperError.contract(
            "artifact inventory directory changed before traversal"
        )
    }

    var rows: [InventoryRow] = []
    for name in try directoryEntryNames(directoryDescriptor) {
        guard let entry = try entrySnapshot(
            parentDescriptor: directoryDescriptor,
            name: name
        ) else {
            throw EvidencePathHelperError.contract(
                "artifact inventory entry disappeared before traversal"
            )
        }
        let childRelativePath = "\(relativePath)/\(name)"
        if entry.isDirectory {
            try requireRepositoryDirectory(
                entry,
                repositoryDevice: repositoryDevice
            )
            let childDescriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else {
                throw EvidencePathHelperError.posix(
                    "open artifact inventory directory",
                    errno
                )
            }
            do {
                let opened = try descriptorSnapshot(childDescriptor)
                guard opened == entry else {
                    throw EvidencePathHelperError.contract(
                        "artifact inventory directory changed while opening"
                    )
                }
                rows.append(
                    contentsOf: try inventoryRows(
                        directoryDescriptor: childDescriptor,
                        captured: opened,
                        relativePath: childRelativePath,
                        repositoryDevice: repositoryDevice
                    )
                )
                let current = try entrySnapshot(
                    parentDescriptor: directoryDescriptor,
                    name: name
                )
                guard try descriptorSnapshot(childDescriptor) == opened,
                      current == opened
                else {
                    throw EvidencePathHelperError.contract(
                        "artifact inventory directory changed during traversal"
                    )
                }
            } catch {
                Darwin.close(childDescriptor)
                throw error
            }
            Darwin.close(childDescriptor)
        } else if entry.isRegularFile {
            try requireRepositoryFile(
                entry,
                repositoryDevice: repositoryDevice
            )
            let fileDescriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else {
                throw EvidencePathHelperError.posix(
                    "open artifact inventory file",
                    errno
                )
            }
            do {
                rows.append(
                    try inventoryRowForRegularFile(
                        descriptor: fileDescriptor,
                        captured: entry,
                        parentDescriptor: directoryDescriptor,
                        name: name,
                        relativePath: childRelativePath,
                        repositoryDevice: repositoryDevice
                    )
                )
            } catch {
                Darwin.close(fileDescriptor)
                throw error
            }
            Darwin.close(fileDescriptor)
        } else {
            throw EvidencePathHelperError.contract(
                "artifact inventory rejects symbolic links and special files"
            )
        }
    }

    guard try descriptorSnapshot(directoryDescriptor) == captured else {
        throw EvidencePathHelperError.contract(
            "artifact inventory directory changed during traversal"
        )
    }
    return rows
}

private func captureInventory(
    repositoryRoot: String,
    outputPath: String,
    candidatePaths: [String]
) throws {
    guard candidatePaths.isEmpty == false else {
        throw EvidencePathHelperError.contract(
            "artifact inventory requires at least one input"
        )
    }
    let candidates = try candidatePaths.map {
        try BoundInventoryCandidate(
            repositoryRoot: repositoryRoot,
            requestedPath: $0
        )
    }
    let output = try BoundInventoryOutput(
        repositoryRoot: repositoryRoot,
        requestedPath: outputPath
    )
    for candidate in candidates {
        switch candidate.kind {
        case .directory:
            break
        case .file:
            guard output.relativePath != candidate.relativePath else {
                throw EvidencePathHelperError.contract(
                    "artifact inventory output cannot replace an input file"
                )
            }
        }
    }

    try TestInterposition.pauseIfRequested()
    for candidate in candidates {
        try candidate.validateBinding()
    }
    try output.validateBinding()

    var rows: [InventoryRow] = []
    for candidate in candidates {
        switch candidate.kind {
        case let .directory(descriptor, captured):
            rows.append(
                contentsOf: try inventoryRows(
                    directoryDescriptor: descriptor,
                    captured: captured,
                    relativePath: candidate.relativePath,
                    repositoryDevice: candidate.repositoryDevice
                )
            )
        case let .file(descriptor, captured):
            rows.append(
                try inventoryRowForRegularFile(
                    descriptor: descriptor,
                    captured: captured,
                    parentDescriptor: nil,
                    name: nil,
                    relativePath: candidate.relativePath,
                    repositoryDevice: candidate.repositoryDevice
                )
            )
        }
        try candidate.validateBinding()
    }
    guard rows.isEmpty == false else {
        throw EvidencePathHelperError.contract(
            "artifact inventory has no files"
        )
    }
    rows.sort {
        $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    for index in rows.indices.dropFirst() {
        guard rows[index - 1].relativePath != rows[index].relativePath else {
            throw EvidencePathHelperError.contract(
                "artifact inventory inputs overlap"
            )
        }
    }
    for candidate in candidates {
        try candidate.validateBinding()
    }
    try output.validateBinding()

    var serialized = ""
    for row in rows {
        serialized += "\(row.digest)\t\(row.size)\t\(row.relativePath)\n"
    }
    guard let data = serialized.data(using: .utf8) else {
        throw EvidencePathHelperError.contract(
            "artifact inventory could not be encoded"
        )
    }
    try output.publish(data)
}

private enum TestInterposition {
    static func pauseIfRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        let readyValue = environment["NOONMARK_EVIDENCE_TEST_READY_FD"]
        let releaseValue = environment["NOONMARK_EVIDENCE_TEST_RELEASE_FD"]
        guard readyValue != nil || releaseValue != nil else { return }
        guard let readyValue,
              let releaseValue,
              let readyDescriptor = exactDescriptor(readyValue),
              let releaseDescriptor = exactDescriptor(releaseValue)
        else {
            throw EvidencePathHelperError.contract(
                "evidence test interposition requires two inherited descriptors"
            )
        }

        var readyByte = UInt8(ascii: "R")
        let written = withUnsafeBytes(of: &readyByte) { bytes in
            Darwin.write(readyDescriptor, bytes.baseAddress, 1)
        }
        guard written == 1 else {
            throw EvidencePathHelperError.posix(
                "signal evidence test interposition",
                errno
            )
        }

        var pollDescriptor = pollfd(
            fd: releaseDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        var pollResult: Int32
        repeat {
            pollResult = Darwin.poll(&pollDescriptor, 1, 2000)
        } while pollResult < 0 && errno == EINTR
        guard pollResult == 1,
              pollDescriptor.revents & Int16(POLLIN) != 0
        else {
            throw EvidencePathHelperError.contract(
                "evidence test interposition release timed out"
            )
        }

        var releaseByte: UInt8 = 0
        let received = withUnsafeMutableBytes(of: &releaseByte) { bytes in
            Darwin.read(releaseDescriptor, bytes.baseAddress, 1)
        }
        guard received == 1, releaseByte == UInt8(ascii: "G") else {
            throw EvidencePathHelperError.contract(
                "evidence test interposition release was invalid"
            )
        }
    }

    private static func exactDescriptor(_ value: String) -> Int32? {
        guard let descriptor = Int32(value), descriptor >= 3,
              String(descriptor) == value,
              fcntl(descriptor, F_GETFD) >= 0
        else { return nil }
        return descriptor
    }
}

private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
    let enumerationDescriptor = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard enumerationDescriptor >= 0 else {
        throw EvidencePathHelperError.posix(
            "open evidence directory for enumeration",
            errno
        )
    }
    do {
        let original = try BoundDirectoryChain.requireDirectory(
            descriptor: descriptor
        )
        let enumerated = try BoundDirectoryChain.requireDirectory(
            descriptor: enumerationDescriptor
        )
        guard original == enumerated else {
            throw EvidencePathHelperError.contract(
                "evidence directory changed before enumeration"
            )
        }
    } catch {
        Darwin.close(enumerationDescriptor)
        throw error
    }
    guard let stream = fdopendir(enumerationDescriptor) else {
        let code = errno
        Darwin.close(enumerationDescriptor)
        throw EvidencePathHelperError.posix(
            "enumerate evidence directory",
            code
        )
    }
    defer { closedir(stream) }

    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(stream) else {
            guard errno == 0 else {
                throw EvidencePathHelperError.posix(
                    "read evidence directory entry",
                    errno
                )
            }
            break
        }
        var value = entry.pointee.d_name
        let length = Int(entry.pointee.d_namlen)
        let name = withUnsafeBytes(of: &value) { bytes in
            String(bytes: bytes.prefix(length), encoding: .utf8)
        }
        guard let name else {
            throw EvidencePathHelperError.contract(
                "evidence directory contains a non-UTF-8 name"
            )
        }
        guard name != ".", name != ".." else { continue }
        try BoundDirectoryChain.validateComponent(name)
        names.append(name)
    }
    return names
}

private func clearDirectory(
    _ descriptor: Int32,
    repositoryDevice: dev_t
) throws {
    try BoundDirectoryChain.requireOwnedDirectory(
        descriptor: descriptor,
        repositoryDevice: repositoryDevice
    )
    for name in try directoryEntryNames(descriptor) {
        var information = stat()
        let inspectionResult = name.withCString {
            Darwin.fstatat(
                descriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectionResult == 0 else {
            throw EvidencePathHelperError.posix(
                "inspect stale evidence entry",
                errno
            )
        }
        if information.st_mode & S_IFMT == S_IFDIR {
            guard information.st_uid == geteuid() else {
                throw EvidencePathHelperError.contract(
                    "stale evidence directory has the wrong owner"
                )
            }
            guard information.st_dev == repositoryDevice else {
                throw EvidencePathHelperError.contract(
                    "stale evidence directory crosses a filesystem boundary"
                )
            }
            let childDescriptor = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else {
                throw EvidencePathHelperError.posix(
                    "open stale evidence directory",
                    errno
                )
            }
            defer { Darwin.close(childDescriptor) }
            var openedInformation = stat()
            guard fstat(childDescriptor, &openedInformation) == 0,
                  DescriptorIdentity(openedInformation)
                    == DescriptorIdentity(information),
                  openedInformation.st_uid == geteuid(),
                  openedInformation.st_dev == repositoryDevice
            else {
                throw EvidencePathHelperError.contract(
                    "stale evidence directory changed before cleanup"
                )
            }
            try clearDirectory(
                childDescriptor,
                repositoryDevice: repositoryDevice
            )
            var finalInformation = stat()
            let finalResult = name.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &finalInformation,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard finalResult == 0,
                  DescriptorIdentity(finalInformation)
                    == DescriptorIdentity(openedInformation)
            else {
                throw EvidencePathHelperError.contract(
                    "stale evidence directory changed during cleanup"
                )
            }
            let removalResult = name.withCString {
                Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
            }
            guard removalResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "remove stale evidence directory",
                    errno
                )
            }
        } else {
            let removalResult = name.withCString {
                Darwin.unlinkat(descriptor, $0, 0)
            }
            guard removalResult == 0 else {
                throw EvidencePathHelperError.posix(
                    "remove stale evidence entry",
                    errno
                )
            }
        }
    }
    guard try directoryEntryNames(descriptor).isEmpty else {
        throw EvidencePathHelperError.contract(
            "evidence directory changed during cleanup"
        )
    }
}

private func prepareFreshDirectory(
    repositoryRoot: String,
    requestedPath: String
) throws {
    let components = try BoundDirectoryChain.relativeComponents(
        requestedPath: requestedPath,
        repositoryRoot: repositoryRoot
    )
    let chain = try BoundDirectoryChain(absolutePath: repositoryRoot)
    for component in components {
        try chain.openChildDirectory(
            named: component,
            createIfMissing: true
        )
    }
    try TestInterposition.pauseIfRequested()
    try chain.validateBindings()
    guard let repositoryDevice = chain.repositoryDevice else {
        throw EvidencePathHelperError.contract(
            "evidence repository boundary is missing"
        )
    }
    try clearDirectory(
        chain.descriptor,
        repositoryDevice: repositoryDevice
    )
    guard fchmod(chain.descriptor, mode_t(0o755)) == 0 else {
        throw EvidencePathHelperError.posix(
            "set evidence directory permissions",
            errno
        )
    }
    try chain.validateBindings()
}

private func run(arguments: [String]) throws {
    guard arguments.count >= 2 else {
        throw EvidencePathHelperError.contract(
            "evidence path helper command is missing"
        )
    }
    switch arguments[1] {
    case "prepare":
        guard arguments.count == 4 else {
            throw EvidencePathHelperError.contract(
                "usage: NoonmarkEvidencePathHelper prepare <repository-root> <path>"
            )
        }
        try prepareFreshDirectory(
            repositoryRoot: arguments[2],
            requestedPath: arguments[3]
        )
    case "inventory":
        guard arguments.count >= 5 else {
            throw EvidencePathHelperError.contract(
                "usage: NoonmarkEvidencePathHelper inventory <repository-root> <output> <input>..."
            )
        }
        try captureInventory(
            repositoryRoot: arguments[2],
            outputPath: arguments[3],
            candidatePaths: Array(arguments.dropFirst(4))
        )
    case "replace-path":
        guard arguments.count == 4 else {
            throw EvidencePathHelperError.contract(
                "usage: NoonmarkEvidencePathHelper replace-path <destination> <source>"
            )
        }
        try replaceFragment(
            destinationPath: arguments[2],
            sourcePath: arguments[3]
        )
    case "append-manifest-path":
        guard arguments.count == 4 else {
            throw EvidencePathHelperError.contract(
                "usage: NoonmarkEvidencePathHelper append-manifest-path <destination> <addition>"
            )
        }
        try appendManifest(
            destinationPath: arguments[2],
            additionPath: arguments[3]
        )
    case "serve":
        guard arguments.count == 4,
              let callerPID = Int32(arguments[3]),
              callerPID > 1,
              String(callerPID) == arguments[3]
        else {
            throw EvidencePathHelperError.contract(
                "usage: NoonmarkEvidencePathHelper serve <transport-root> <caller-pid>"
            )
        }
        try serveSession(
            transportPath: arguments[2],
            callerPID: callerPID
        )
    case "bootstrap-cleanup-contract":
        guard arguments.count == 2 else {
            throw EvidencePathHelperError.contract(
                "bootstrap cleanup contract accepts no arguments"
            )
        }
        try TestInterposition.pauseIfRequested()
    default:
        throw EvidencePathHelperError.contract(
            "unknown evidence path helper command"
        )
    }
}

do {
    let bootstrap = try BootstrapContext(arguments: CommandLine.arguments)
    try run(arguments: bootstrap.commandArguments)
} catch {
    fputs("Noonmark evidence path helper: \(error)\n", stderr)
    exit(1)
}
