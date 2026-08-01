import Darwin
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

private enum CustodianError: Error, CustomStringConvertible {
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

private struct Snapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let linkCount: nlink_t

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
        mode = information.st_mode
        owner = information.st_uid
        linkCount = information.st_nlink
    }

    var kind: mode_t {
        mode & S_IFMT
    }

    func matchesDirectoryObject(_ other: Snapshot) -> Bool {
        device == other.device &&
            inode == other.inode &&
            mode == other.mode &&
            owner == other.owner &&
            kind == S_IFDIR &&
            other.kind == S_IFDIR
    }

    func matchesNamedObject(_ other: Snapshot) -> Bool {
        device == other.device &&
            inode == other.inode &&
            mode == other.mode &&
            owner == other.owner &&
            linkCount == other.linkCount
    }
}

private func descriptorSnapshot(_ descriptor: Int32) throws -> Snapshot {
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
        throw CustodianError.posix("inspect bootstrap descriptor", errno)
    }
    return Snapshot(information)
}

private func entrySnapshot(
    parentDescriptor: Int32,
    name: String
) throws -> Snapshot? {
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
        throw CustodianError.posix("inspect bootstrap entry", errno)
    }
    return Snapshot(information)
}

private func validateName(_ name: String) throws {
    guard name.hasPrefix("noonmark-evidence-path-helper."),
          name.count <= 96,
          name.unicodeScalars.allSatisfy({
              CharacterSet.alphanumerics.contains($0) ||
                  $0 == "." || $0 == "-"
          })
    else {
        throw CustodianError.contract("bootstrap name is invalid")
    }
}

private func absoluteParentAndName(_ path: String) throws -> (String, String) {
    guard path.hasPrefix("/"), path != "/",
          path.hasSuffix("/") == false,
          path.contains("//") == false,
          path.contains("\n") == false,
          path.contains("\r") == false,
          path.contains("\t") == false
    else {
        throw CustodianError.contract("session transport path is invalid")
    }
    let components = path.split(separator: "/").map(String.init)
    guard components.count >= 2,
          components.allSatisfy({
              $0.isEmpty == false && $0 != "." && $0 != ".."
          }),
          "/" + components.joined(separator: "/") == path
    else {
        throw CustodianError.contract("session transport path is not canonical")
    }
    return (
        "/" + components.dropLast().joined(separator: "/"),
        components[components.count - 1]
    )
}

private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
    let enumerationDescriptor = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard enumerationDescriptor >= 0 else {
        throw CustodianError.posix("open bootstrap for enumeration", errno)
    }
    guard let stream = fdopendir(enumerationDescriptor) else {
        let code = errno
        Darwin.close(enumerationDescriptor)
        throw CustodianError.posix("enumerate bootstrap", code)
    }
    defer { closedir(stream) }

    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(stream) else {
            guard errno == 0 else {
                throw CustodianError.posix("read bootstrap entry", errno)
            }
            break
        }
        var storage = entry.pointee.d_name
        let length = Int(entry.pointee.d_namlen)
        let name = withUnsafeBytes(of: &storage) { bytes in
            String(bytes: bytes.prefix(length), encoding: .utf8)
        }
        guard let name else {
            throw CustodianError.contract("bootstrap name is not UTF-8")
        }
        if name != ".", name != ".." {
            names.append(name)
        }
    }
    return names
}

private enum CustodianInterposition {
    static func pauseIfRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        let readyValue = environment[
            "NOONMARK_EVIDENCE_CUSTODIAN_TEST_READY_FD"
        ]
        let releaseValue = environment[
            "NOONMARK_EVIDENCE_CUSTODIAN_TEST_RELEASE_FD"
        ]
        guard readyValue != nil || releaseValue != nil else { return }
        guard let readyValue, let releaseValue,
              let readyDescriptor = exactDescriptor(readyValue),
              let releaseDescriptor = exactDescriptor(releaseValue)
        else {
            throw CustodianError.contract(
                "custodian interposition descriptors are invalid"
            )
        }
        var ready = UInt8(ascii: "R")
        let written = withUnsafeBytes(of: &ready) { bytes in
            Darwin.write(readyDescriptor, bytes.baseAddress, 1)
        }
        guard written == 1 else {
            throw CustodianError.posix("publish custodian interposition", errno)
        }
        var pollDescriptor = pollfd(
            fd: releaseDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        var result: Int32
        repeat {
            result = Darwin.poll(&pollDescriptor, 1, 2000)
        } while result < 0 && errno == EINTR
        guard result == 1,
              pollDescriptor.revents & Int16(POLLIN) != 0
        else {
            throw CustodianError.contract(
                "custodian interposition release timed out"
            )
        }
        var release = UInt8(0)
        let received = withUnsafeMutableBytes(of: &release) { bytes in
            Darwin.read(releaseDescriptor, bytes.baseAddress, 1)
        }
        guard received == 1, release == UInt8(ascii: "G") else {
            throw CustodianError.contract(
                "custodian interposition release is invalid"
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

private final class SessionTransportFallback {
    private let parentDescriptor: Int32
    private let rootDescriptor: Int32
    private let rootName: String
    private let rootIdentity: Snapshot
    private let fifoSnapshots: [String: Snapshot]
    private let expectedNames = [
        "lock.fifo",
        "request.fifo",
        "response.fifo",
    ]

    init(path: String, requireComplete: Bool = true) throws {
        let (parentPath, rootName) = try absoluteParentAndName(path)
        guard rootName.hasPrefix("noonmark-evidence-helper-session."),
              rootName.count <= 96,
              rootName.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) ||
                      $0 == "." || $0 == "-"
              })
        else {
            throw CustodianError.contract("session transport name is invalid")
        }
        let parentDescriptor = parentPath.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard parentDescriptor >= 0 else {
            throw CustodianError.posix("open session transport parent", errno)
        }
        let rootDescriptor = rootName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            let code = errno
            Darwin.close(parentDescriptor)
            throw CustodianError.posix("open session transport root", code)
        }
        do {
            let parent = try descriptorSnapshot(parentDescriptor)
            let root = try descriptorSnapshot(rootDescriptor)
            let entryNames = try directoryEntryNames(rootDescriptor).sorted()
            guard root.kind == S_IFDIR,
                  root.owner == geteuid(),
                  root.device == parent.device,
                  root.mode & mode_t(0o777) == mode_t(0o700),
                  try entrySnapshot(
                      parentDescriptor: parentDescriptor,
                      name: rootName
                  )?.matchesDirectoryObject(root) == true,
                  requireComplete
                  ? entryNames == expectedNames
                  : entryNames.allSatisfy(expectedNames.contains)
            else {
                throw CustodianError.contract(
                    "session transport root binding is unsafe"
                )
            }
            var snapshots: [String: Snapshot] = [:]
            for name in entryNames {
                guard let snapshot = try entrySnapshot(
                    parentDescriptor: rootDescriptor,
                    name: name
                ), snapshot.kind == S_IFIFO,
                    snapshot.owner == geteuid(),
                    snapshot.device == root.device,
                    snapshot.linkCount == 1,
                    requireComplete == false ||
                        snapshot.mode & mode_t(0o777) == mode_t(0o600)
                else {
                    throw CustodianError.contract(
                        "session transport FIFO is unsafe"
                    )
                }
                snapshots[name] = snapshot
            }
            self.parentDescriptor = parentDescriptor
            self.rootDescriptor = rootDescriptor
            self.rootName = rootName
            rootIdentity = root
            fifoSnapshots = snapshots
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(rootDescriptor)
        Darwin.close(parentDescriptor)
    }

    func cleanup() throws {
        guard try descriptorSnapshot(rootDescriptor)
            .matchesDirectoryObject(rootIdentity)
        else {
            throw CustodianError.contract(
                "session transport root descriptor changed"
            )
        }
        let namesBefore = try directoryEntryNames(rootDescriptor).sorted()
        guard namesBefore.allSatisfy(expectedNames.contains) else {
            throw CustodianError.contract(
                "session transport contains unexpected entries"
            )
        }
        for name in namesBefore {
            guard let captured = fifoSnapshots[name],
                  try entrySnapshot(
                      parentDescriptor: rootDescriptor,
                      name: name
                  )?.matchesNamedObject(captured) == true
            else {
                throw CustodianError.contract(
                    "session transport FIFO binding changed"
                )
            }
        }
        for name in namesBefore {
            let result = name.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw CustodianError.posix(
                    "remove session transport FIFO",
                    errno
                )
            }
        }
        guard try directoryEntryNames(rootDescriptor).isEmpty else {
            throw CustodianError.contract(
                "session transport root did not become empty"
            )
        }
        guard let namedRoot = try entrySnapshot(
            parentDescriptor: parentDescriptor,
            name: rootName
        ) else {
            guard namesBefore.isEmpty else {
                throw CustodianError.contract(
                    "session transport name binding changed"
                )
            }
            return
        }
        guard namedRoot.matchesDirectoryObject(rootIdentity) else {
            throw CustodianError.contract(
                "session transport name binding changed"
            )
        }
        let result = rootName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw CustodianError.posix("remove session transport root", errno)
        }
    }
}

private func cleanupBootstrapResidue(path: String) throws {
    let (parentPath, rootName) = try absoluteParentAndName(path)
    try validateName(rootName)
    let parentDescriptor = parentPath.withCString {
        Darwin.open(
            $0,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
    }
    guard parentDescriptor >= 0 else {
        throw CustodianError.posix("open bootstrap residue parent", errno)
    }
    defer { Darwin.close(parentDescriptor) }
    let rootDescriptor = rootName.withCString {
        Darwin.openat(
            parentDescriptor,
            $0,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
    }
    guard rootDescriptor >= 0 else {
        throw CustodianError.posix("open bootstrap residue root", errno)
    }
    defer { Darwin.close(rootDescriptor) }

    let parent = try descriptorSnapshot(parentDescriptor)
    let root = try descriptorSnapshot(rootDescriptor)
    guard root.kind == S_IFDIR,
          root.owner == geteuid(),
          root.device == parent.device,
          root.mode & mode_t(0o777) == mode_t(0o700),
          try entrySnapshot(
              parentDescriptor: parentDescriptor,
              name: rootName
          )?.matchesDirectoryObject(root) == true
    else {
        throw CustodianError.contract(
            "bootstrap residue root binding is unsafe"
        )
    }
    let helperName = "NoonmarkEvidencePathHelper"
    let controlName = "custodian-control.fifo"
    let readyName = "custodian-ready"
    let allowed = [helperName, controlName, readyName]
    let names = try directoryEntryNames(rootDescriptor)
    guard names.allSatisfy(allowed.contains) else {
        throw CustodianError.contract(
            "bootstrap residue contains unexpected entries"
        )
    }
    for name in names {
        guard let entry = try entrySnapshot(
            parentDescriptor: rootDescriptor,
            name: name
        ), entry.owner == geteuid(), entry.linkCount == 1,
            entry.device == root.device,
            entry.mode & mode_t(0o777)
            == (name == helperName ? mode_t(0o700) : mode_t(0o600)),
            name == controlName ? entry.kind == S_IFIFO : entry.kind == S_IFREG
        else {
            throw CustodianError.contract(
                "bootstrap residue entry is unsafe"
            )
        }
    }
    for name in names {
        let result = name.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        guard result == 0 else {
            throw CustodianError.posix(
                "remove bootstrap residue entry",
                errno
            )
        }
    }
    guard try directoryEntryNames(rootDescriptor).isEmpty,
          try entrySnapshot(
              parentDescriptor: parentDescriptor,
              name: rootName
          )?.matchesDirectoryObject(root) == true
    else {
        throw CustodianError.contract(
            "bootstrap residue root binding changed"
        )
    }
    let result = rootName.withCString {
        Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
    }
    guard result == 0 else {
        throw CustodianError.posix("remove bootstrap residue root", errno)
    }
}

private final class BootstrapCustodian {
    private let parentDescriptor: Int32
    private let rootDescriptor: Int32
    private let queueDescriptor: Int32
    private let controlDescriptor: Int32
    private let rootName: String
    private let rootIdentity: Snapshot
    private let parentDevice: dev_t
    private let launcherPID: pid_t
    private let sessionFallback: SessionTransportFallback?

    private let helperName = "NoonmarkEvidencePathHelper"
    private let controlName = "custodian-control.fifo"
    private let readyName = "custodian-ready"

    init(
        temporaryParent: String,
        rootName: String,
        launcherPID: pid_t,
        sessionFallback: SessionTransportFallback?
    ) throws {
        try validateName(rootName)
        guard temporaryParent.hasPrefix("/"),
              launcherPID > 1,
              kill(launcherPID, 0) == 0 || errno == EPERM
        else {
            throw CustodianError.contract("bootstrap custodian input is invalid")
        }
        let parentDescriptor = temporaryParent.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard parentDescriptor >= 0 else {
            throw CustodianError.posix("open bootstrap parent", errno)
        }
        let parentSnapshot: Snapshot
        do {
            parentSnapshot = try descriptorSnapshot(parentDescriptor)
        } catch {
            Darwin.close(parentDescriptor)
            throw error
        }
        guard parentSnapshot.kind == S_IFDIR else {
            Darwin.close(parentDescriptor)
            throw CustodianError.contract("bootstrap parent is not a directory")
        }
        let creationResult = rootName.withCString {
            Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
        }
        guard creationResult == 0 else {
            let code = errno
            Darwin.close(parentDescriptor)
            throw CustodianError.posix("create bootstrap root", code)
        }
        let rootDescriptor = rootName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            let code = errno
            let rollbackResult = rootName.withCString {
                Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            let rollbackCode = errno
            Darwin.close(parentDescriptor)
            guard rollbackResult == 0 else {
                throw CustodianError.posix(
                    "roll back unopened bootstrap root",
                    rollbackCode
                )
            }
            throw CustodianError.posix("open bootstrap root", code)
        }

        do {
            let rootSnapshot = try descriptorSnapshot(rootDescriptor)
            guard rootSnapshot.kind == S_IFDIR,
                  rootSnapshot.owner == geteuid(),
                  rootSnapshot.device == parentSnapshot.device,
                  rootSnapshot.mode & mode_t(0o777) == mode_t(0o700),
                  try entrySnapshot(
                      parentDescriptor: parentDescriptor,
                      name: rootName
                  ) == rootSnapshot
            else {
                throw CustodianError.contract("bootstrap root binding is unsafe")
            }
            let controlResult = controlName.withCString {
                Darwin.mkfifoat(rootDescriptor, $0, mode_t(0o600))
            }
            guard controlResult == 0 else {
                throw CustodianError.posix("create custodian control FIFO", errno)
            }
            let controlDescriptor = controlName.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard controlDescriptor >= 0 else {
                throw CustodianError.posix("open custodian control FIFO", errno)
            }
            try CustodianInterposition.pauseIfRequested()

            let queueDescriptor = kqueue()
            guard queueDescriptor >= 0 else {
                Darwin.close(controlDescriptor)
                throw CustodianError.posix("create custodian kqueue", errno)
            }
            var processEvent = kevent()
            processEvent.ident = UInt(launcherPID)
            processEvent.filter = Int16(EVFILT_PROC)
            processEvent.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
            processEvent.fflags = UInt32(NOTE_EXIT)
            let registration = withUnsafePointer(to: &processEvent) {
                systemKevent(
                    queueDescriptor,
                    $0,
                    1,
                    nil,
                    0,
                    nil
                )
            }
            guard registration == 0 else {
                let code = errno
                Darwin.close(queueDescriptor)
                Darwin.close(controlDescriptor)
                throw CustodianError.posix("monitor launcher process", code)
            }
            guard kill(launcherPID, 0) == 0 || errno == EPERM else {
                Darwin.close(queueDescriptor)
                Darwin.close(controlDescriptor)
                throw CustodianError.contract(
                    "launcher exited during custodian startup"
                )
            }

            let readyDescriptor = readyName.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard readyDescriptor >= 0 else {
                Darwin.close(queueDescriptor)
                Darwin.close(controlDescriptor)
                throw CustodianError.posix("create custodian ready marker", errno)
            }
            var marker = UInt8(ascii: "R")
            let written = withUnsafeBytes(of: &marker) { bytes in
                Darwin.write(readyDescriptor, bytes.baseAddress, 1)
            }
            let readySync = fsync(readyDescriptor)
            Darwin.close(readyDescriptor)
            guard written == 1, readySync == 0 else {
                Darwin.close(queueDescriptor)
                Darwin.close(controlDescriptor)
                throw CustodianError.posix("publish custodian ready marker", errno)
            }

            self.parentDescriptor = parentDescriptor
            self.rootDescriptor = rootDescriptor
            self.queueDescriptor = queueDescriptor
            self.controlDescriptor = controlDescriptor
            self.rootName = rootName
            rootIdentity = rootSnapshot
            parentDevice = parentSnapshot.device
            self.launcherPID = launcherPID
            self.sessionFallback = sessionFallback
        } catch {
            var rollbackError: Error?
            do {
                try Self.rollbackBootstrap(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: rootDescriptor,
                    rootName: rootName,
                    parentDevice: parentSnapshot.device
                )
            } catch {
                rollbackError = error
            }
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            if let rollbackError { throw rollbackError }
            throw error
        }
    }

    deinit {
        Darwin.close(controlDescriptor)
        Darwin.close(queueDescriptor)
        Darwin.close(rootDescriptor)
        Darwin.close(parentDescriptor)
    }

    func waitAndClean() throws {
        while true {
            var event = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
            let eventCount = withUnsafeMutablePointer(to: &event) { pointer in
                withUnsafePointer(to: &timeout) { timeoutPointer in
                    systemKevent(
                        queueDescriptor,
                        nil,
                        0,
                        pointer,
                        1,
                        timeoutPointer
                    )
                }
            }
            if eventCount < 0, errno != EINTR {
                throw CustodianError.posix("wait for launcher exit", errno)
            }
            if eventCount == 1, event.filter == Int16(EVFILT_PROC) {
                break
            }
            var byte: UInt8 = 0
            let received = withUnsafeMutableBytes(of: &byte) { bytes in
                Darwin.read(controlDescriptor, bytes.baseAddress, 1)
            }
            if received == 1 {
                guard byte == UInt8(ascii: "Q") else {
                    throw CustodianError.contract("custodian control byte is invalid")
                }
                break
            }
            if received < 0, errno != EAGAIN, errno != EINTR {
                throw CustodianError.posix("read custodian control", errno)
            }
            if kill(launcherPID, 0) != 0, errno != EPERM {
                break
            }
        }
        var sessionError: Error?
        do {
            try sessionFallback?.cleanup()
        } catch {
            sessionError = error
        }
        var bootstrapError: Error?
        do {
            try cleanup()
        } catch {
            bootstrapError = error
        }
        if let sessionError { throw sessionError }
        if let bootstrapError { throw bootstrapError }
    }

    private static func rollbackBootstrap(
        parentDescriptor: Int32,
        rootDescriptor: Int32,
        rootName: String,
        parentDevice: dev_t
    ) throws {
        let root = try descriptorSnapshot(rootDescriptor)
        guard root.kind == S_IFDIR,
              root.owner == geteuid(),
              root.device == parentDevice,
              root.mode & mode_t(0o777) == mode_t(0o700),
              try entrySnapshot(
                  parentDescriptor: parentDescriptor,
                  name: rootName
              )?.matchesDirectoryObject(root) == true
        else {
            throw CustodianError.contract(
                "bootstrap rollback binding is unsafe"
            )
        }
        let allowed = [
            "custodian-control.fifo",
            "custodian-ready",
        ]
        let names = try directoryEntryNames(rootDescriptor)
        guard names.allSatisfy(allowed.contains) else {
            throw CustodianError.contract(
                "bootstrap rollback contains unexpected entries"
            )
        }
        for name in names {
            guard let entry = try entrySnapshot(
                parentDescriptor: rootDescriptor,
                name: name
            ), entry.owner == geteuid(), entry.linkCount == 1,
                entry.device == parentDevice,
                name == "custodian-ready"
                    ? entry.kind == S_IFREG
                    : entry.kind == S_IFIFO
            else {
                throw CustodianError.contract(
                    "bootstrap rollback entry is unsafe"
                )
            }
            let result = name.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw CustodianError.posix(
                    "remove bootstrap rollback entry",
                    errno
                )
            }
        }
        guard try directoryEntryNames(rootDescriptor).isEmpty else {
            throw CustodianError.contract(
                "bootstrap rollback root did not become empty"
            )
        }
        let result = rootName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw CustodianError.posix("remove bootstrap rollback root", errno)
        }
    }

    private func cleanup() throws {
        guard try descriptorSnapshot(rootDescriptor)
            .matchesDirectoryObject(rootIdentity)
        else {
            throw CustodianError.contract("bootstrap root descriptor changed")
        }
        let names = try directoryEntryNames(rootDescriptor).sorted()
        let expected = [controlName, helperName, readyName].sorted()
        let expectedWithoutHelper = [controlName, readyName].sorted()
        guard names == expected || names == expectedWithoutHelper else {
            throw CustodianError.contract("bootstrap root contains unexpected entries")
        }
        if names.contains(helperName) {
            guard let helper = try entrySnapshot(
                parentDescriptor: rootDescriptor,
                name: helperName
            ), helper.kind == S_IFREG,
                helper.owner == geteuid(),
                helper.linkCount == 1,
                helper.device == parentDevice
            else {
                throw CustodianError.contract("bootstrap helper entry is unsafe")
            }
            let result = helperName.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw CustodianError.posix("remove bootstrap helper", errno)
            }
        }
        for name in [readyName, controlName] {
            guard let entry = try entrySnapshot(
                parentDescriptor: rootDescriptor,
                name: name
            ), entry.owner == geteuid(), entry.linkCount == 1,
                entry.device == parentDevice,
                name == readyName ? entry.kind == S_IFREG : entry.kind == S_IFIFO
            else {
                throw CustodianError.contract("bootstrap custodian entry is unsafe")
            }
            let result = name.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw CustodianError.posix("remove bootstrap custodian entry", errno)
            }
        }
        guard try directoryEntryNames(rootDescriptor).isEmpty else {
            throw CustodianError.contract("bootstrap root did not become empty")
        }
        guard try entrySnapshot(
            parentDescriptor: parentDescriptor,
            name: rootName
        ) == rootIdentity else {
            throw CustodianError.contract("bootstrap root name binding changed")
        }
        let result = rootName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw CustodianError.posix("remove bootstrap root", errno)
        }
    }
}

private func exactPID(_ value: String) -> pid_t? {
    guard let pid = Int32(value), pid > 1, String(pid) == value else {
        return nil
    }
    return pid
}

do {
    Darwin.signal(SIGHUP, SIG_IGN)
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--recover-session" {
        let fallback = try SessionTransportFallback(
            path: arguments[2],
            requireComplete: false
        )
        try fallback.cleanup()
        exit(0)
    }
    if arguments.count == 3, arguments[1] == "--recover-bootstrap" {
        try cleanupBootstrapResidue(path: arguments[2])
        exit(0)
    }
    guard arguments.count == 4 || arguments.count == 6,
          let launcherPID = exactPID(arguments[3])
    else {
        throw CustodianError.contract(
            "usage: NoonmarkEvidenceBootstrapCustodian <temp-parent> <root-name> <launcher-pid> [--session-transport <path>]"
        )
    }
    let sessionFallback: SessionTransportFallback?
    if arguments.count == 6 {
        guard arguments[4] == "--session-transport" else {
            throw CustodianError.contract(
                "custodian optional argument is invalid"
            )
        }
        sessionFallback = try SessionTransportFallback(path: arguments[5])
    } else {
        sessionFallback = nil
    }
    let custodian: BootstrapCustodian
    do {
        custodian = try BootstrapCustodian(
            temporaryParent: arguments[1],
            rootName: arguments[2],
            launcherPID: launcherPID,
            sessionFallback: sessionFallback
        )
    } catch {
        try sessionFallback?.cleanup()
        throw error
    }
    try custodian.waitAndClean()
} catch {
    fputs("Noonmark evidence bootstrap custodian: \(error)\n", stderr)
    exit(1)
}
