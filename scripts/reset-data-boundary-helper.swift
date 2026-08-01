import Darwin
import Foundation

private enum ResetBoundaryError: Error {
    case invalidInvocation
    case invalidProfile
    case invalidPath
    case namespaceChanged
    case unsupportedEntry
    case posix(Int32)
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ information: stat) {
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
    }
}

private final class OwnedDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        _ = Darwin.close(rawValue)
    }
}

private struct ComponentBinding {
    let parent: OwnedDescriptor
    let name: String
    let child: OwnedDescriptor
    let identity: FileIdentity
}

private struct TargetBinding {
    let components: [String]
    let bindings: [ComponentBinding]
    let firstMissingIndex: Int?
}

private struct RuntimeResetScope {
    let relativeTargets: [String]

    init(profile: String) throws {
        let dataDirectory: String
        let iCloudRoot: String
        let bundleIdentifier: String
        switch profile {
        case "development":
            dataDirectory = "noonmark-development"
            iCloudRoot = "Noonmark-Development"
            bundleIdentifier = "app.noonmark.mac.development"
        case "e2e":
            dataDirectory = "noonmark-e2e"
            iCloudRoot = "Noonmark-E2E"
            bundleIdentifier = "app.noonmark.mac.e2e"
        case "demo":
            dataDirectory = "noonmark-demo"
            iCloudRoot = "Noonmark-Demo"
            bundleIdentifier = "app.noonmark.mac.demo"
        case "audit":
            dataDirectory = "noonmark-audit"
            iCloudRoot = "Noonmark-Audit"
            bundleIdentifier = "app.noonmark.mac.audit"
        case "dmg-validation":
            dataDirectory = "noonmark-dmg-validation"
            iCloudRoot = "Noonmark-DMGValidation"
            bundleIdentifier = "app.noonmark.mac.dmg-validation"
        default:
            throw ResetBoundaryError.invalidProfile
        }

        relativeTargets = [
            "Library/Application Support/\(dataDirectory)",
            "Library/Mobile Documents/com~apple~CloudDocs/\(iCloudRoot)",
            "Library/Caches/\(bundleIdentifier)",
            "Library/Saved Application State/\(bundleIdentifier).savedState"
        ]
    }
}

private final class AbsoluteDirectoryBinding {
    let descriptor: OwnedDescriptor
    let identity: FileIdentity
    private let rootDescriptor: OwnedDescriptor
    private let bindings: [ComponentBinding]
    private let requiresFinalOwner: Bool
    private let exactFinalPermissions: mode_t?

    init(
        canonicalPath: String,
        requiresFinalOwner: Bool,
        exactFinalPermissions: mode_t? = nil
    ) throws {
        let components = try Self.absoluteComponents(canonicalPath)

        let rawRoot = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rawRoot >= 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        let rootDescriptor = OwnedDescriptor(rawRoot)
        var current = rootDescriptor
        var bindings: [ComponentBinding] = []
        for component in components {
            var namedInformation = stat()
            guard fstatat(
                current.rawValue,
                component,
                &namedInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            namedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw ResetBoundaryError.invalidPath
            }
            let rawChild = openat(
                current.rawValue,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rawChild >= 0 else {
                throw ResetBoundaryError.posix(errno)
            }
            let child = OwnedDescriptor(rawChild)
            var openedInformation = stat()
            guard fstat(rawChild, &openedInformation) == 0,
                  openedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  FileIdentity(openedInformation) == FileIdentity(namedInformation)
            else {
                throw ResetBoundaryError.namespaceChanged
            }
            bindings.append(
                ComponentBinding(
                    parent: current,
                    name: component,
                    child: child,
                    identity: FileIdentity(openedInformation)
                )
            )
            current = child
        }

        guard let finalBinding = bindings.last else {
            throw ResetBoundaryError.invalidPath
        }
        var finalInformation = stat()
        guard fstat(finalBinding.child.rawValue, &finalInformation) == 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        try Self.validateFinalDirectory(
            finalInformation,
            requiresOwner: requiresFinalOwner,
            exactPermissions: exactFinalPermissions,
            error: ResetBoundaryError.invalidPath
        )

        self.rootDescriptor = rootDescriptor
        self.bindings = bindings
        self.requiresFinalOwner = requiresFinalOwner
        self.exactFinalPermissions = exactFinalPermissions
        descriptor = finalBinding.child
        identity = FileIdentity(finalInformation)
        try validate()
    }

    func validate() throws {
        var rootInformation = stat()
        guard fstat(rootDescriptor.rawValue, &rootInformation) == 0,
              rootInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ResetBoundaryError.namespaceChanged
        }
        for (index, binding) in bindings.enumerated() {
            var information = stat()
            guard fstatat(
                binding.parent.rawValue,
                binding.name,
                &information,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            FileIdentity(information) == binding.identity
            else {
                throw ResetBoundaryError.namespaceChanged
            }
            if index == bindings.count - 1 {
                try Self.validateFinalDirectory(
                    information,
                    requiresOwner: requiresFinalOwner,
                    exactPermissions: exactFinalPermissions,
                    error: ResetBoundaryError.namespaceChanged
                )
            }
        }
    }

    private static func absoluteComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path != "/" else {
            throw ResetBoundaryError.invalidPath
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !components.isEmpty else {
            throw ResetBoundaryError.invalidPath
        }
        return components
    }

    private static func validateFinalDirectory(
        _ information: stat,
        requiresOwner: Bool,
        exactPermissions: mode_t?,
        error: ResetBoundaryError
    ) throws {
        if requiresOwner, information.st_uid != geteuid() {
            throw error
        }
        if let exactPermissions {
            let permissions = information.st_mode & mode_t(0o777)
            if permissions != exactPermissions {
                throw error
            }
        }
    }
}

private final class BootstrapDirectory {
    private let parentDescriptor: OwnedDescriptor
    private let directoryDescriptor: OwnedDescriptor
    private let name: String
    private let identity: FileIdentity
    private var didClean = false

    init(canonicalPath: String) throws {
        guard canonicalPath.hasPrefix("/"), canonicalPath != "/" else {
            throw ResetBoundaryError.invalidPath
        }
        let components = canonicalPath.split(separator: "/").map(String.init)
        guard let finalName = components.last, !finalName.isEmpty else {
            throw ResetBoundaryError.invalidPath
        }

        let rawRoot = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rawRoot >= 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        var current = OwnedDescriptor(rawRoot)
        var finalParent: OwnedDescriptor?
        var finalDirectory: OwnedDescriptor?
        var finalIdentity: FileIdentity?

        for (index, component) in components.enumerated() {
            var namedInformation = stat()
            guard fstatat(
                current.rawValue,
                component,
                &namedInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            namedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw ResetBoundaryError.invalidPath
            }
            let rawChild = openat(
                current.rawValue,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rawChild >= 0 else {
                throw ResetBoundaryError.posix(errno)
            }
            let child = OwnedDescriptor(rawChild)
            var openedInformation = stat()
            guard fstat(rawChild, &openedInformation) == 0,
                  openedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  FileIdentity(openedInformation) == FileIdentity(namedInformation)
            else {
                throw ResetBoundaryError.namespaceChanged
            }

            if index == components.count - 1 {
                let permissions = openedInformation.st_mode & mode_t(0o777)
                guard openedInformation.st_uid == geteuid(),
                      permissions == mode_t(0o700)
                else {
                    throw ResetBoundaryError.invalidPath
                }
                finalParent = current
                finalDirectory = child
                finalIdentity = FileIdentity(openedInformation)
            }
            current = child
        }

        guard let finalParent,
              let finalDirectory,
              let finalIdentity
        else {
            throw ResetBoundaryError.invalidPath
        }
        parentDescriptor = finalParent
        directoryDescriptor = finalDirectory
        name = finalName
        identity = finalIdentity
    }

    func clean() {
        guard !didClean else { return }
        didClean = true
        for entry in [
            "reset-data-boundary-helper",
            "control.fifo",
            "status.fifo"
        ] {
            let removalFailed = unlinkat(
                directoryDescriptor.rawValue,
                entry,
                0
            ) != 0
            if removalFailed, errno != ENOENT {
                return
            }
        }

        var namedInformation = stat()
        guard fstatat(
            parentDescriptor.rawValue,
            name,
            &namedInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        namedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        FileIdentity(namedInformation) == identity
        else {
            return
        }
        _ = unlinkat(parentDescriptor.rawValue, name, AT_REMOVEDIR)
    }
}

private final class ResetDataBoundary {
    private let homePathBinding: AbsoluteDirectoryBinding
    private let homeDescriptor: OwnedDescriptor
    private let homeIdentity: FileIdentity
    private let targets: [TargetBinding]

    init(canonicalHome: String, scope: RuntimeResetScope) throws {
        let homePathBinding = try AbsoluteDirectoryBinding(
            canonicalPath: canonicalHome,
            requiresFinalOwner: true
        )
        let homeDescriptor = homePathBinding.descriptor
        var openedInformation = stat()
        guard fstat(homeDescriptor.rawValue, &openedInformation) == 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        try Self.validateOwnedDirectory(openedInformation)
        guard homePathBinding.identity == FileIdentity(openedInformation) else {
            throw ResetBoundaryError.namespaceChanged
        }

        let boundHomeIdentity = FileIdentity(openedInformation)
        self.homePathBinding = homePathBinding
        self.homeDescriptor = homeDescriptor
        homeIdentity = boundHomeIdentity
        targets = try scope.relativeTargets.map {
            try Self.bindTarget(
                relativePath: $0,
                homeDescriptor: homeDescriptor,
                expectedDevice: boundHomeIdentity.device
            )
        }

        try validateAllBindings(expectTargetsAbsent: false)
        for target in targets {
            guard target.firstMissingIndex == nil else { continue }
            guard let leaf = target.bindings.last else {
                throw ResetBoundaryError.invalidPath
            }
            try Self.preflightTree(
                descriptor: leaf.child.rawValue,
                expectedDevice: homeIdentity.device
            )
        }
    }

    func deleteBoundTargets() throws {
        try validateBoundTargets()
        for target in targets {
            guard target.firstMissingIndex == nil,
                  let leaf = target.bindings.last
            else {
                continue
            }

            try Self.preflightTree(
                descriptor: leaf.child.rawValue,
                expectedDevice: homeIdentity.device
            )
            try Self.removeContents(
                descriptor: leaf.child.rawValue,
                expectedDevice: homeIdentity.device
            )
            try Self.requireNamedIdentity(
                parentDescriptor: leaf.parent.rawValue,
                name: leaf.name,
                expected: leaf.identity
            )
            guard unlinkat(
                leaf.parent.rawValue,
                leaf.name,
                AT_REMOVEDIR
            ) == 0 else {
                throw ResetBoundaryError.posix(errno)
            }
        }
        try validateAllBindings(expectTargetsAbsent: true)
    }

    func validateBoundTargets() throws {
        try validateAllBindings(expectTargetsAbsent: false)
        for target in targets {
            guard target.firstMissingIndex == nil else { continue }
            guard let leaf = target.bindings.last else {
                throw ResetBoundaryError.invalidPath
            }
            try Self.preflightTree(
                descriptor: leaf.child.rawValue,
                expectedDevice: homeIdentity.device
            )
        }
    }

    private func validateAllBindings(expectTargetsAbsent: Bool) throws {
        try homePathBinding.validate()

        var openedHome = stat()
        guard fstat(homeDescriptor.rawValue, &openedHome) == 0,
              FileIdentity(openedHome) == homeIdentity
        else {
            throw ResetBoundaryError.namespaceChanged
        }

        for target in targets {
            try validate(
                target: target,
                expectTargetAbsent: expectTargetsAbsent
            )
        }
    }

    private func validate(
        target: TargetBinding,
        expectTargetAbsent: Bool
    ) throws {
        for (index, binding) in target.bindings.enumerated() {
            let isLeaf = index == target.components.count - 1
            if expectTargetAbsent, isLeaf {
                try Self.requireNamedEntryAbsent(
                    parentDescriptor: binding.parent.rawValue,
                    name: binding.name
                )
                return
            }
            try Self.requireNamedIdentity(
                parentDescriptor: binding.parent.rawValue,
                name: binding.name,
                expected: binding.identity
            )
        }

        if let missingIndex = target.firstMissingIndex {
            let parent = target.bindings.last?.child ?? homeDescriptor
            try Self.requireNamedEntryAbsent(
                parentDescriptor: parent.rawValue,
                name: target.components[missingIndex]
            )
        }
    }

    private static func bindTarget(
        relativePath: String,
        homeDescriptor: OwnedDescriptor,
        expectedDevice: UInt64
    ) throws -> TargetBinding {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\n")
              })
        else {
            throw ResetBoundaryError.invalidPath
        }

        var bindings: [ComponentBinding] = []
        var current = homeDescriptor
        for (index, component) in components.enumerated() {
            var namedInformation = stat()
            guard fstatat(
                current.rawValue,
                component,
                &namedInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT {
                    return TargetBinding(
                        components: components,
                        bindings: bindings,
                        firstMissingIndex: index
                    )
                }
                throw ResetBoundaryError.posix(errno)
            }
            try validateOwnedDirectory(namedInformation)
            guard UInt64(namedInformation.st_dev) == expectedDevice else {
                throw ResetBoundaryError.invalidPath
            }

            let rawChild = openat(
                current.rawValue,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rawChild >= 0 else {
                throw ResetBoundaryError.posix(errno)
            }
            let child = OwnedDescriptor(rawChild)
            var openedInformation = stat()
            guard fstat(rawChild, &openedInformation) == 0 else {
                throw ResetBoundaryError.posix(errno)
            }
            try validateOwnedDirectory(openedInformation)
            guard UInt64(openedInformation.st_dev) == expectedDevice else {
                throw ResetBoundaryError.invalidPath
            }
            let identity = FileIdentity(namedInformation)
            guard identity == FileIdentity(openedInformation) else {
                throw ResetBoundaryError.namespaceChanged
            }
            bindings.append(
                ComponentBinding(
                    parent: current,
                    name: component,
                    child: child,
                    identity: identity
                )
            )
            current = child
        }
        return TargetBinding(
            components: components,
            bindings: bindings,
            firstMissingIndex: nil
        )
    }

    private static func preflightTree(
        descriptor: Int32,
        expectedDevice: UInt64
    ) throws {
        for name in try entryNames(descriptor: descriptor) {
            var information = stat()
            guard fstatat(
                descriptor,
                name,
                &information,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw ResetBoundaryError.posix(errno)
            }
            let type = information.st_mode & mode_t(S_IFMT)
            guard type != 0 else {
                throw ResetBoundaryError.unsupportedEntry
            }
            if type == mode_t(S_IFDIR) {
                guard information.st_uid == geteuid(),
                      UInt64(information.st_dev) == expectedDevice
                else {
                    throw ResetBoundaryError.invalidPath
                }
                let child = try openMatchingDirectory(
                    parentDescriptor: descriptor,
                    name: name,
                    namedInformation: information,
                    expectedDevice: expectedDevice
                )
                try preflightTree(
                    descriptor: child.rawValue,
                    expectedDevice: expectedDevice
                )
                try requireNamedIdentity(
                    parentDescriptor: descriptor,
                    name: name,
                    expected: FileIdentity(information)
                )
            }
        }
    }

    private static func removeContents(
        descriptor: Int32,
        expectedDevice: UInt64
    ) throws {
        for name in try entryNames(descriptor: descriptor) {
            var information = stat()
            guard fstatat(
                descriptor,
                name,
                &information,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT { continue }
                throw ResetBoundaryError.posix(errno)
            }
            let type = information.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                guard information.st_uid == geteuid(),
                      UInt64(information.st_dev) == expectedDevice
                else {
                    throw ResetBoundaryError.invalidPath
                }
                let child = try openMatchingDirectory(
                    parentDescriptor: descriptor,
                    name: name,
                    namedInformation: information,
                    expectedDevice: expectedDevice
                )
                try removeContents(
                    descriptor: child.rawValue,
                    expectedDevice: expectedDevice
                )
                try requireNamedIdentity(
                    parentDescriptor: descriptor,
                    name: name,
                    expected: FileIdentity(information)
                )
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw ResetBoundaryError.posix(errno)
                }
            } else {
                guard unlinkat(descriptor, name, 0) == 0 else {
                    if errno == ENOENT { continue }
                    throw ResetBoundaryError.posix(errno)
                }
            }
        }
    }

    private static func openMatchingDirectory(
        parentDescriptor: Int32,
        name: String,
        namedInformation: stat,
        expectedDevice: UInt64
    ) throws -> OwnedDescriptor {
        let rawChild = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rawChild >= 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        let child = OwnedDescriptor(rawChild)
        var openedInformation = stat()
        guard fstat(rawChild, &openedInformation) == 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        guard openedInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              openedInformation.st_uid == geteuid(),
              UInt64(openedInformation.st_dev) == expectedDevice,
              FileIdentity(openedInformation) == FileIdentity(namedInformation)
        else {
            throw ResetBoundaryError.namespaceChanged
        }
        return child
    }

    private static func requireNamedIdentity(
        parentDescriptor: Int32,
        name: String,
        expected: FileIdentity
    ) throws {
        var information = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        FileIdentity(information) == expected
        else {
            throw ResetBoundaryError.namespaceChanged
        }
    }

    private static func requireNamedEntryAbsent(
        parentDescriptor: Int32,
        name: String
    ) throws {
        var information = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) != 0,
        errno == ENOENT
        else {
            throw ResetBoundaryError.namespaceChanged
        }
    }

    private static func entryNames(descriptor: Int32) throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else {
            throw ResetBoundaryError.posix(errno)
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            let openError = errno
            _ = Darwin.close(enumerationDescriptor)
            throw ResetBoundaryError.posix(openError)
        }
        defer { closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw ResetBoundaryError.posix(errno)
                }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(length), encoding: .utf8)
            }
            guard let name else {
                throw ResetBoundaryError.invalidPath
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    private static func validateOwnedDirectory(_ information: stat) throws {
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == geteuid()
        else {
            throw ResetBoundaryError.invalidPath
        }
    }
}

private func writeProtocolLine(_ line: String) throws {
    let data = Data("\(line)\n".utf8)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func readProtocolLine() throws -> String? {
    var data = Data()
    while data.count <= 32 {
        guard let next = try FileHandle.standardInput.read(upToCount: 1),
              !next.isEmpty
        else {
            return data.isEmpty ? nil : String(data: data, encoding: .utf8)
        }
        if next == Data([0x0A]) {
            return String(data: data, encoding: .utf8)
        }
        data.append(next)
    }
    throw ResetBoundaryError.invalidInvocation
}

private func run() throws {
    guard CommandLine.arguments.count == 4 else {
        throw ResetBoundaryError.invalidInvocation
    }
    let bootstrap = try BootstrapDirectory(
        canonicalPath: CommandLine.arguments[3]
    )
    defer { bootstrap.clean() }
    let scope = try RuntimeResetScope(profile: CommandLine.arguments[1])
    let boundary = try ResetDataBoundary(
        canonicalHome: CommandLine.arguments[2],
        scope: scope
    )
    try writeProtocolLine("READY")

    guard let firstCommand = try readProtocolLine() else {
        return
    }
    let finalCommand: String
    if firstCommand == "VALIDATE" {
        try boundary.validateBoundTargets()
        try writeProtocolLine("VALIDATED")
        guard let nextCommand = try readProtocolLine() else { return }
        finalCommand = nextCommand
    } else {
        finalCommand = firstCommand
    }
    guard finalCommand == "GO" else {
        throw ResetBoundaryError.invalidInvocation
    }
    try boundary.deleteBoundTargets()
    try writeProtocolLine("DONE")
}

do {
    try run()
} catch {
    let code = switch error {
    case ResetBoundaryError.invalidInvocation: "invalid-invocation"
    case ResetBoundaryError.invalidProfile: "invalid-profile"
    case ResetBoundaryError.invalidPath: "invalid-path"
    case ResetBoundaryError.namespaceChanged: "namespace-changed"
    case ResetBoundaryError.unsupportedEntry: "unsupported-entry"
    case let ResetBoundaryError.posix(value): "posix-\(value)"
    default: "unexpected"
    }
    try? writeProtocolLine("ERROR:\(code)")
    FileHandle.standardError.write(Data("reset-boundary-error:\(code)\n".utf8))
    exit(1)
}
