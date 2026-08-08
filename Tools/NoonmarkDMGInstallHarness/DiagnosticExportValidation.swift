import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import NoonmarkDiagnostics

/// Holds the two persistence locks that must not be prerequisites for
/// diagnostic export. Construction is fail-closed and proves that both locks
/// are contended before the UI interaction starts.
final class DiagnosticExportLocks {
    private let targetPID: pid_t
    private let repositoryDirectory: DescriptorBoundDirectory
    private let databaseFile: DescriptorBoundFile
    private let sharedMemoryFile: DescriptorBoundFile
    private let repositoryFile: DescriptorBoundFile
    private let databaseIdentity: stat
    private let sharedMemoryIdentity: stat
    private let sqliteLockHolder: SQLiteByteRangeLockHolder
    private var released = false

    convenience init(
        scope: PinnedDiagnosticExportScope,
        targetPID: pid_t
    ) throws {
        guard let executablePath = Bundle.main.executableURL?.path else {
            throw Self.contract("helper executable path is unavailable")
        }
        try self.init(
            databaseDirectory: scope.databaseDirectory,
            databaseFileName: scope.databaseFileName,
            repositoryDirectory: scope.repositoryDirectory,
            repositoryLockFileName: scope.repositoryLockFileName,
            targetPID: targetPID,
            lockHolderExecutablePath: executablePath
        )
    }

    init(
        databaseDirectory: DescriptorBoundDirectory,
        databaseFileName: String,
        repositoryDirectory: DescriptorBoundDirectory,
        repositoryLockFileName: String,
        targetPID: pid_t,
        lockHolderExecutablePath: String
    ) throws {
        let databaseFile = try databaseDirectory.openExistingFile(
            named: databaseFileName,
            writable: true
        )
        let databaseIdentity = try databaseFile.identity()
        try Self.validateWALDatabase(
            databaseFile,
            identity: databaseIdentity
        )

        let sharedMemoryFileName = databaseFileName + "-shm"
        try CanonicalAbsolutePath.validate(component: sharedMemoryFileName)
        let sharedMemoryFile = try databaseDirectory.openExistingFile(
            named: sharedMemoryFileName,
            writable: true
        )
        let sharedMemoryIdentity = try sharedMemoryFile.identity()
        guard sharedMemoryIdentity.st_size > SQLiteByteRangeLockHolder
            .walWriteLockOffset
        else {
            throw Self.contract(
                "diagnostic SQLite shared-memory file is too small for its writer lock"
            )
        }

        try TargetProcessVnodeBindings.prove(
            targetPID: targetPID,
            expected: [databaseIdentity, sharedMemoryIdentity]
        )
        let sqliteLockHolder = try SQLiteByteRangeLockHolder(
            executablePath: lockHolderExecutablePath,
            databaseDescriptor: databaseFile.descriptor,
            databaseIdentity: databaseIdentity,
            sharedMemoryDescriptor: sharedMemoryFile.descriptor,
            sharedMemoryIdentity: sharedMemoryIdentity
        )

        let openedRepository = try repositoryDirectory.createOrOpenFile(
            named: repositoryLockFileName,
            mode: mode_t(S_IRUSR | S_IWUSR)
        )
        let repositoryFile = openedRepository.file
        let initialRepositoryIdentity = try repositoryFile.identity()
        if openedRepository.created {
            guard initialRepositoryIdentity.st_size == 0 else {
                throw Self.contract("new repository lock file is not empty")
            }
            guard fchmod(
                repositoryFile.descriptor,
                mode_t(S_IRUSR | S_IWUSR)
            ) == 0 else {
                throw Self.posixFailure(
                    "set new repository lock permissions",
                    code: errno
                )
            }
        }
        let repositoryIdentity = try repositoryFile.identity()
        guard repositoryIdentity.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
            == (S_IRUSR | S_IWUSR),
            repositoryIdentity.st_size <= 64 * 1024
        else {
            throw Self.contract(
                "repository lock is not a bounded owner-only regular file"
            )
        }
        try repositoryFile.validateNameStillBound(to: repositoryIdentity)
        guard flock(repositoryFile.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Self.posixFailure("acquire repository lock", code: errno)
        }

        try databaseFile.validateNameStillBound(to: databaseIdentity)
        try sharedMemoryFile.validateNameStillBound(to: sharedMemoryIdentity)
        try databaseDirectory.validatePathBinding()
        try repositoryDirectory.validatePathBinding()

        self.targetPID = targetPID
        self.repositoryDirectory = repositoryDirectory
        self.databaseFile = databaseFile
        self.sharedMemoryFile = sharedMemoryFile
        self.repositoryFile = repositoryFile
        self.databaseIdentity = databaseIdentity
        self.sharedMemoryIdentity = sharedMemoryIdentity
        self.sqliteLockHolder = sqliteLockHolder
    }

    deinit {
        if released == false {
            _ = flock(repositoryFile.descriptor, LOCK_UN)
        }
    }

    func proveContention(
        step: String,
        ledger: HarnessLedger?
    ) throws {
        try databaseFile.validateNameStillBound(to: databaseIdentity)
        try sharedMemoryFile.validateNameStillBound(to: sharedMemoryIdentity)
        try TargetProcessVnodeBindings.prove(
            targetPID: targetPID,
            expected: [databaseIdentity, sharedMemoryIdentity]
        )
        try sqliteLockHolder.proveLocks(
            databaseDescriptor: databaseFile.descriptor,
            sharedMemoryDescriptor: sharedMemoryFile.descriptor
        )
        try proveRepositoryContention()
        let databaseVnode = TargetProcessVnodeBindings.Identity(
            databaseIdentity
        )
        let sharedMemoryVnode = TargetProcessVnodeBindings.Identity(
            sharedMemoryIdentity
        )
        try ledger?.pass(
            "diagnostic-locks-\(step)",
            "sqlite_writer=busy repository_flock=would-block held=true "
                + "target_vnodes=bound target_pid=\(targetPID) "
                + "main_dev=\(databaseVnode.device) "
                + "main_ino=\(databaseVnode.inode) "
                + "shm_dev=\(sharedMemoryVnode.device) "
                + "shm_ino=\(sharedMemoryVnode.inode)"
        )
    }

    func release(ledger: HarnessLedger?) throws {
        guard released == false else {
            throw Self.contract("diagnostic locks were released more than once")
        }
        try sqliteLockHolder.shutdown()
        guard flock(repositoryFile.descriptor, LOCK_UN) == 0 else {
            throw Self.posixFailure("release repository lock", code: errno)
        }
        released = true
        try ledger?.pass(
            "diagnostic-lock-holder-exit",
            sqliteLockHolder.evidence + " normal_exit=true exit_code=0"
        )
    }

    private func proveRepositoryContention() throws {
        let contender = try repositoryDirectory.openExistingFile(
            named: repositoryFile.name,
            writable: true
        )
        let result = flock(contender.descriptor, LOCK_EX | LOCK_NB)
        guard result == -1,
              errno == EWOULDBLOCK || errno == EAGAIN
        else {
            if result == 0 { _ = flock(contender.descriptor, LOCK_UN) }
            throw Self.contract(
                "repository lock contention probe did not return EWOULDBLOCK"
            )
        }
        try repositoryFile.validateNameStillBound(
            to: try repositoryFile.identity()
        )
    }

    private static func validateWALDatabase(
        _ file: DescriptorBoundFile,
        identity: stat
    ) throws {
        guard identity.st_size >= 100 else {
            throw contract("diagnostic database is too small for a SQLite header")
        }
        var header = [UInt8](repeating: 0, count: 100)
        let count = header.withUnsafeMutableBytes { bytes in
            Darwin.pread(file.descriptor, bytes.baseAddress, bytes.count, 0)
        }
        let signature = Array("SQLite format 3\0".utf8)
        guard count == header.count,
              Array(header.prefix(signature.count)) == signature,
              header[18] == 2,
              header[19] == 2
        else {
            throw contract("diagnostic database is not an exact WAL-mode SQLite file")
        }
        let after = try file.identity()
        guard DescriptorBoundFile.sameObject(identity, after) else {
            throw contract("diagnostic database identity changed during validation")
        }
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }

    private static func posixFailure(
        _ operation: String,
        code: Int32
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(
            "\(operation) failed: errno=\(code) "
                + String(cString: strerror(code))
        )
    }
}

final class SQLiteByteRangeLockHolder {
    static let childMode = "--noonmark-internal-sqlite-lock-holder-v1"
    static let databaseReservedLockOffset: off_t = 0x4000_0001
    static let walWriteLockOffset: off_t = 120

    private static let databaseChildDescriptor: Int32 = 200
    private static let sharedMemoryChildDescriptor: Int32 = 201
    private static let readyChildDescriptor: Int32 = 202
    private static let releaseChildDescriptor: Int32 = 203
    private static let stagingDescriptorMinimum: Int32 = 300
    private static let readinessMagic: UInt64 = 0x4E4D_4C4F_434B_5631
    private static let readinessTimeoutSeconds = 5
    private static let shutdownTimeoutSeconds = 5

    private struct Readiness {
        var magic: UInt64 = 0
        var childPID: Int32 = 0
        var parentPID: Int32 = 0
        var result: Int32 = -1
        var reserved: Int32 = 0
        var tokenProof: UInt64 = 0
        var databaseDevice: UInt64 = 0
        var databaseInode: UInt64 = 0
        var sharedMemoryDevice: UInt64 = 0
        var sharedMemoryInode: UInt64 = 0
    }

    private let childPID: pid_t
    private let token: String
    private let databaseIdentity: TargetProcessVnodeBindings.Identity
    private let sharedMemoryIdentity: TargetProcessVnodeBindings.Identity
    private var releaseDescriptor: Int32
    private var reaped = false

    init(
        executablePath: String,
        databaseDescriptor: Int32,
        databaseIdentity: stat,
        sharedMemoryDescriptor: Int32,
        sharedMemoryIdentity: stat,
        watchdogSeconds: Int = 180
    ) throws {
        guard watchdogSeconds >= 1, watchdogSeconds <= 300 else {
            throw Self.contract("SQLite lock-holder watchdog is out of bounds")
        }
        _ = try CanonicalAbsolutePath(executablePath)
        let token = UUID().uuidString
        let parentPID = getpid()
        let databaseVnode = TargetProcessVnodeBindings.Identity(databaseIdentity)
        let sharedMemoryVnode = TargetProcessVnodeBindings.Identity(
            sharedMemoryIdentity
        )

        var readyPipe = [Int32](repeating: -1, count: 2)
        var releasePipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&readyPipe) == 0 else {
            throw Self.posixFailure("create SQLite lock readiness pipe", code: errno)
        }
        do {
            try Self.configurePipe(readyPipe)
            guard Darwin.pipe(&releasePipe) == 0 else {
                throw Self.posixFailure(
                    "create SQLite lock release pipe",
                    code: errno
                )
            }
            try Self.configurePipe(releasePipe)
        } catch {
            readyPipe.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            releasePipe.filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            throw error
        }

        let arguments = [
            executablePath,
            Self.childMode,
            token,
            String(parentPID),
            String(watchdogSeconds),
            String(databaseVnode.device),
            String(databaseVnode.inode),
            String(sharedMemoryVnode.device),
            String(sharedMemoryVnode.inode)
        ]
        let pid: pid_t
        do {
            pid = try Self.spawn(
                executablePath: executablePath,
                arguments: arguments,
                descriptorMappings: [
                    (databaseDescriptor, Self.databaseChildDescriptor),
                    (sharedMemoryDescriptor, Self.sharedMemoryChildDescriptor),
                    (readyPipe[1], Self.readyChildDescriptor),
                    (releasePipe[0], Self.releaseChildDescriptor)
                ]
            )
        } catch {
            readyPipe.forEach { _ = Darwin.close($0) }
            releasePipe.forEach { _ = Darwin.close($0) }
            throw error
        }

        _ = Darwin.close(readyPipe[1])
        _ = Darwin.close(releasePipe[0])
        do {
            try Self.waitUntilReadable(
                descriptor: readyPipe[0],
                timeoutSeconds: Self.readinessTimeoutSeconds,
                operation: "wait for SQLite lock-holder readiness"
            )
            let readiness: Readiness = try Self.readExact(
                descriptor: readyPipe[0]
            )
            guard readiness.magic == Self.readinessMagic,
                  readiness.childPID == pid,
                  readiness.parentPID == parentPID,
                  readiness.result == 0,
                  readiness.tokenProof == Self.tokenProof(token),
                  readiness.databaseDevice == databaseVnode.device,
                  readiness.databaseInode == databaseVnode.inode,
                  readiness.sharedMemoryDevice == sharedMemoryVnode.device,
                  readiness.sharedMemoryInode == sharedMemoryVnode.inode
            else {
                throw Self.contract(
                    "SQLite lock-holder readiness did not match its exact spawn contract: "
                        + "magic=\(readiness.magic) child=\(readiness.childPID)/\(pid) "
                        + "parent=\(readiness.parentPID)/\(parentPID) "
                        + "result=\(readiness.result) "
                        + "token=\(readiness.tokenProof)/\(Self.tokenProof(token)) "
                        + "main=\(readiness.databaseDevice):\(readiness.databaseInode)/"
                        + "\(databaseVnode.device):\(databaseVnode.inode) "
                        + "shm=\(readiness.sharedMemoryDevice):"
                        + "\(readiness.sharedMemoryInode)/\(sharedMemoryVnode.device):"
                        + "\(sharedMemoryVnode.inode)"
                )
            }
        } catch {
            _ = Darwin.close(readyPipe[0])
            _ = Darwin.close(releasePipe[1])
            Self.terminateAndReap(pid)
            throw error
        }
        _ = Darwin.close(readyPipe[0])

        childPID = pid
        self.token = token
        self.databaseIdentity = databaseVnode
        self.sharedMemoryIdentity = sharedMemoryVnode
        releaseDescriptor = releasePipe[1]
    }

    deinit {
        if releaseDescriptor >= 0 {
            _ = Darwin.close(releaseDescriptor)
            releaseDescriptor = -1
        }
        if reaped == false {
            Self.terminateAndReap(childPID, sendsSignalFirst: false)
        }
    }

    static func isChildInvocation(_ arguments: [String]) -> Bool {
        arguments.first == childMode
    }

    static func runSpawnedChild(_ arguments: [String]) -> Never {
        guard arguments.count == 8,
              arguments[0] == childMode,
              let token = canonicalToken(arguments[1]),
              let parentPID = pid_t(arguments[2]),
              parentPID > 1,
              getppid() == parentPID,
              let watchdogSeconds = Int(arguments[3]),
              (1 ... 300).contains(watchdogSeconds),
              let databaseDevice = UInt64(arguments[4]),
              let databaseInode = UInt64(arguments[5]),
              let sharedMemoryDevice = UInt64(arguments[6]),
              let sharedMemoryInode = UInt64(arguments[7])
        else {
            _exit(64)
        }
        let databaseIdentity = TargetProcessVnodeBindings.Identity(
            device: databaseDevice,
            inode: databaseInode
        )
        let sharedMemoryIdentity = TargetProcessVnodeBindings.Identity(
            device: sharedMemoryDevice,
            inode: sharedMemoryInode
        )
        let descriptorValidation = validateChildDescriptors(
            databaseIdentity: databaseIdentity,
            sharedMemoryIdentity: sharedMemoryIdentity
        )
        guard descriptorValidation == 0 else {
            writeReadiness(
                result: descriptorValidation,
                token: token,
                parentPID: parentPID,
                databaseIdentity: databaseIdentity,
                sharedMemoryIdentity: sharedMemoryIdentity
            )
            _exit(65)
        }

        var databaseLock = lock(
            type: Int16(F_WRLCK),
            offset: databaseReservedLockOffset
        )
        var sharedMemoryLock = lock(
            type: Int16(F_WRLCK),
            offset: walWriteLockOffset
        )
        var result: Int32 = 0
        if fcntl(databaseChildDescriptor, F_SETLK, &databaseLock) != 0 {
            result = errno
        } else if fcntl(
            sharedMemoryChildDescriptor,
            F_SETLK,
            &sharedMemoryLock
        ) != 0 {
            result = errno
            databaseLock.l_type = Int16(F_UNLCK)
            _ = fcntl(databaseChildDescriptor, F_SETLK, &databaseLock)
        }
        writeReadiness(
            result: result,
            token: token,
            parentPID: parentPID,
            databaseIdentity: databaseIdentity,
            sharedMemoryIdentity: sharedMemoryIdentity
        )
        _ = Darwin.close(readyChildDescriptor)
        guard result == 0 else {
            _ = Darwin.close(releaseChildDescriptor)
            _exit(66)
        }

        let released = waitForRelease(timeoutSeconds: watchdogSeconds)
        sharedMemoryLock.l_type = Int16(F_UNLCK)
        databaseLock.l_type = Int16(F_UNLCK)
        _ = fcntl(sharedMemoryChildDescriptor, F_SETLK, &sharedMemoryLock)
        _ = fcntl(databaseChildDescriptor, F_SETLK, &databaseLock)
        _ = Darwin.close(releaseChildDescriptor)
        _ = Darwin.close(sharedMemoryChildDescriptor)
        _ = Darwin.close(databaseChildDescriptor)
        _exit(released ? EXIT_SUCCESS : 67)
    }

    func proveLocks(
        databaseDescriptor: Int32,
        sharedMemoryDescriptor: Int32
    ) throws {
        guard reaped == false else {
            throw Self.contract("SQLite lock-holder was already reaped")
        }
        try proveLock(
            descriptor: databaseDescriptor,
            offset: Self.databaseReservedLockOffset
        )
        try proveLock(
            descriptor: sharedMemoryDescriptor,
            offset: Self.walWriteLockOffset
        )
    }

    func shutdown() throws {
        guard reaped == false, releaseDescriptor >= 0 else {
            throw Self.contract("SQLite lock-holder shutdown was not exactly once")
        }
        _ = Darwin.close(releaseDescriptor)
        releaseDescriptor = -1
        let status = try Self.waitForChildExit(
            childPID,
            timeoutSeconds: Self.shutdownTimeoutSeconds
        )
        reaped = true
        guard Self.normalExitCode(status) == EXIT_SUCCESS else {
            throw Self.contract(
                "SQLite lock-holder did not exit normally after exact release"
            )
        }
    }

    var evidence: String {
        "lock_holder=posix_spawn child_pid=\(childPID) token=\(token) "
            + "main_dev=\(databaseIdentity.device) "
            + "main_ino=\(databaseIdentity.inode) "
            + "shm_dev=\(sharedMemoryIdentity.device) "
            + "shm_ino=\(sharedMemoryIdentity.inode)"
    }

    var childPIDForTesting: pid_t { childPID }

    func waitForWatchdogExpiryForTesting(timeoutSeconds: Int) throws {
        guard reaped == false, releaseDescriptor >= 0 else {
            throw Self.contract("SQLite lock-holder watchdog was already observed")
        }
        let status = try Self.waitForChildExit(
            childPID,
            timeoutSeconds: timeoutSeconds
        )
        reaped = true
        _ = Darwin.close(releaseDescriptor)
        releaseDescriptor = -1
        guard Self.normalExitCode(status) == 67 else {
            throw Self.contract("SQLite lock-holder watchdog exit was not exact")
        }
    }

    private func proveLock(descriptor: Int32, offset: off_t) throws {
        var query = Self.lock(type: Int16(F_WRLCK), offset: offset)
        guard fcntl(descriptor, F_GETLK, &query) == 0 else {
            throw Self.posixFailure("inspect SQLite byte-range lock", code: errno)
        }
        guard query.l_type == Int16(F_WRLCK), query.l_pid == childPID else {
            throw Self.contract(
                "descriptor-bound SQLite writer lock is not held by its exact child"
            )
        }
    }

    private static func spawn(
        executablePath: String,
        arguments: [String],
        descriptorMappings: [(source: Int32, destination: Int32)]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            if actions != nil { posix_spawn_file_actions_destroy(&actions) }
            if attributes != nil { posix_spawnattr_destroy(&attributes) }
            throw contract("initialize SQLite lock-holder spawn contract failed")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let flagResult = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        guard flagResult == 0 else {
            throw posixFailure("set close-on-exec-default spawn flag", code: flagResult)
        }

        var stagingDescriptors: [Int32] = []
        defer { stagingDescriptors.forEach { _ = Darwin.close($0) } }
        for mapping in descriptorMappings {
            let staging = fcntl(
                mapping.source,
                F_DUPFD_CLOEXEC,
                stagingDescriptorMinimum
            )
            guard staging >= 0 else {
                throw posixFailure("stage exact lock-holder descriptor", code: errno)
            }
            stagingDescriptors.append(staging)
            let actionResult = posix_spawn_file_actions_adddup2(
                &actions,
                staging,
                mapping.destination
            )
            guard actionResult == 0 else {
                throw posixFailure(
                    "install exact lock-holder descriptor action",
                    code: actionResult
                )
            }
        }

        let cArguments = arguments.map { strdup($0) }
        guard cArguments.allSatisfy({ $0 != nil }) else {
            cArguments.forEach { free($0) }
            throw contract("allocate SQLite lock-holder arguments failed")
        }
        defer { cArguments.forEach { free($0) } }
        var argumentPointers = cArguments + [nil]
        var emptyEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let result = executablePath.withCString { executable in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                emptyEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        executable,
                        &actions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0, pid > 0 else {
            throw posixFailure("spawn SQLite lock-holder", code: result)
        }
        return pid
    }

    private static func configurePipe(_ descriptors: [Int32]) throws {
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw posixFailure("close-on-exec protect lock-holder pipe", code: errno)
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                throw posixFailure("make lock-holder pipe nonblocking", code: errno)
            }
        }
    }

    private static func validateChildDescriptors(
        databaseIdentity: TargetProcessVnodeBindings.Identity,
        sharedMemoryIdentity: TargetProcessVnodeBindings.Identity
    ) -> Int32 {
        var result: Int32 = 0
        if descriptor(
            databaseChildDescriptor,
            matches: databaseIdentity,
            type: S_IFREG,
            accessMode: O_RDWR
        ) == false { result |= 1 }
        if descriptor(
            sharedMemoryChildDescriptor,
            matches: sharedMemoryIdentity,
            type: S_IFREG,
            accessMode: O_RDWR
        ) == false { result |= 2 }
        if descriptor(
            readyChildDescriptor,
            matches: nil,
            type: S_IFIFO,
            accessMode: O_WRONLY
        ) == false { result |= 4 }
        if descriptor(
            releaseChildDescriptor,
            matches: nil,
            type: S_IFIFO,
            accessMode: O_RDONLY
        ) == false { result |= 8 }

        let byteCount = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return result | 16 }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var values = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(byteCount) / stride + 8
        )
        let readCount = values.withUnsafeMutableBytes { bytes in
            proc_pidinfo(
                getpid(),
                PROC_PIDLISTFDS,
                0,
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard readCount > 0 else { return result | 16 }
        let allowed = Set([
            databaseChildDescriptor,
            sharedMemoryChildDescriptor,
            readyChildDescriptor,
            releaseChildDescriptor
        ])
        let inherited = Set(
            values.prefix(Int(readCount) / stride)
                .map(\.proc_fd)
                .filter { $0 > STDERR_FILENO }
        )
        if inherited != allowed { result |= 16 }
        return result
    }

    private static func descriptor(
        _ descriptor: Int32,
        matches expected: TargetProcessVnodeBindings.Identity?,
        type: mode_t,
        accessMode: Int32
    ) -> Bool {
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        let expectedLinkCount: nlink_t = type == S_IFIFO ? 0 : 1
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == type,
              status.st_uid == geteuid(),
              status.st_nlink == expectedLinkCount,
              flags >= 0,
              flags & O_ACCMODE == accessMode,
              flags & O_NONBLOCK == O_NONBLOCK
        else { return false }
        guard let expected else { return true }
        return TargetProcessVnodeBindings.Identity(status) == expected
    }

    private static func writeReadiness(
        result: Int32,
        token: String,
        parentPID: pid_t,
        databaseIdentity: TargetProcessVnodeBindings.Identity,
        sharedMemoryIdentity: TargetProcessVnodeBindings.Identity
    ) {
        var readiness = Readiness(
            magic: readinessMagic,
            childPID: getpid(),
            parentPID: parentPID,
            result: result,
            reserved: 0,
            tokenProof: tokenProof(token),
            databaseDevice: databaseIdentity.device,
            databaseInode: databaseIdentity.inode,
            sharedMemoryDevice: sharedMemoryIdentity.device,
            sharedMemoryInode: sharedMemoryIdentity.inode
        )
        withUnsafeBytes(of: &readiness) { bytes in
            _ = Darwin.write(
                readyChildDescriptor,
                bytes.baseAddress,
                bytes.count
            )
        }
    }

    private static func waitForRelease(timeoutSeconds: Int) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { _ = Darwin.close(queue) }
        var change = kevent64_s(
            ident: UInt64(releaseChildDescriptor),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        guard kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
            return false
        }
        var event = kevent64_s()
        var timeout = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        guard kevent64(queue, nil, 0, &event, 1, 0, &timeout) == 1,
              event.flags & UInt16(EV_EOF) == UInt16(EV_EOF)
        else { return false }
        var unexpected: UInt8 = 0
        return Darwin.read(releaseChildDescriptor, &unexpected, 1) == 0
    }

    private static func waitUntilReadable(
        descriptor: Int32,
        timeoutSeconds: Int,
        operation: String
    ) throws {
        let queue = kqueue()
        guard queue >= 0 else {
            throw posixFailure("create \(operation) queue", code: errno)
        }
        defer { _ = Darwin.close(queue) }
        var change = kevent64_s(
            ident: UInt64(descriptor),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        guard kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
            throw posixFailure("register \(operation)", code: errno)
        }
        var event = kevent64_s()
        var timeout = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        guard kevent64(queue, nil, 0, &event, 1, 0, &timeout) == 1 else {
            throw contract("\(operation) timed out")
        }
    }

    private static func readExact(
        descriptor: Int32
    ) throws -> Readiness {
        var value = Readiness()
        var offset = 0
        while offset < MemoryLayout<Readiness>.size {
            let count = withUnsafeMutableBytes(of: &value) { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                try waitUntilReadable(
                    descriptor: descriptor,
                    timeoutSeconds: readinessTimeoutSeconds,
                    operation: "complete SQLite lock-holder readiness"
                )
            } else {
                throw contract("SQLite lock-holder readiness was truncated")
            }
        }
        return value
    }

    private static func waitForChildExit(
        _ pid: pid_t,
        timeoutSeconds: Int
    ) throws -> Int32 {
        var status: Int32 = 0
        var immediate: pid_t
        repeat {
            immediate = waitpid(pid, &status, WNOHANG)
        } while immediate < 0 && errno == EINTR
        if immediate == pid {
            return status
        }
        guard immediate == 0 else {
            throw posixFailure("inspect SQLite lock-holder exit", code: errno)
        }

        let queue = kqueue()
        guard queue >= 0 else {
            throw posixFailure("create SQLite lock-holder exit queue", code: errno)
        }
        defer { _ = Darwin.close(queue) }
        var change = kevent64_s(
            ident: UInt64(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS),
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        if kevent64(queue, &change, 1, nil, 0, 0, nil) != 0 {
            let registrationCode = errno
            let racedExit = waitpid(pid, &status, WNOHANG)
            if racedExit == pid { return status }
            if registrationCode == ESRCH, racedExit == 0 {
                return try waitForChildExitAfterRegistrationRace(
                    pid,
                    timeoutSeconds: timeoutSeconds
                )
            }
            throw posixFailure(
                "register SQLite lock-holder exit",
                code: registrationCode
            )
        }
        var event = kevent64_s()
        var timeout = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        guard kevent64(queue, nil, 0, &event, 1, 0, &timeout) == 1 else {
            throw contract("SQLite lock-holder exit timed out")
        }
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else {
                throw posixFailure("reap SQLite lock-holder", code: errno)
            }
        }
        return status
    }

    private static func waitForChildExitAfterRegistrationRace(
        _ pid: pid_t,
        timeoutSeconds: Int
    ) throws -> Int32 {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds) * 1_000_000_000
        var status: Int32 = 0

        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return status }
            if reaped < 0 {
                guard errno == EINTR else {
                    throw posixFailure(
                        "inspect SQLite lock-holder exit after registration race",
                        code: errno
                    )
                }
                continue
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw contract("SQLite lock-holder exit timed out")
            }
            usleep(10_000)
        }
    }

    private static func terminateAndReap(
        _ pid: pid_t,
        sendsSignalFirst: Bool = true
    ) {
        if sendsSignalFirst { _ = Darwin.kill(pid, SIGKILL) }
        if sendsSignalFirst == false {
            if (try? waitForChildExit(
                pid,
                timeoutSeconds: shutdownTimeoutSeconds
            )) != nil {
                return
            }
            _ = Darwin.kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func normalExitCode(_ status: Int32) -> Int32? {
        guard status & 0x7F == 0 else { return nil }
        return (status >> 8) & 0xFF
    }

    private static func canonicalToken(_ rawValue: String) -> String? {
        guard let value = UUID(uuidString: rawValue)?.uuidString,
              value == rawValue else { return nil }
        return value
    }

    private static func tokenProof(_ token: String) -> UInt64 {
        token.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func lock(type: Int16, offset: off_t) -> flock {
        var value = flock()
        value.l_type = type
        value.l_whence = Int16(SEEK_SET)
        value.l_start = offset
        value.l_len = 1
        return value
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }

    private static func posixFailure(
        _ operation: String,
        code: Int32
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(
            "\(operation) failed: errno=\(code) "
                + String(cString: strerror(code))
        )
    }
}

private enum TargetProcessVnodeBindings {
    struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64

        init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
        }

        init(_ value: vinfo_stat) {
            device = UInt64(truncatingIfNeeded: value.vst_dev)
            inode = UInt64(truncatingIfNeeded: value.vst_ino)
        }
    }

    static func prove(targetPID: pid_t, expected: [stat]) throws {
        guard targetPID > 0 else {
            throw contract("target PID is invalid for SQLite vnode binding")
        }
        let expectedIdentities = Set(expected.map(Identity.init))
        let actual = try vnodeIdentities(targetPID: targetPID)
        guard expectedIdentities.isSubset(of: actual) else {
            throw contract(
                "target App does not hold the pinned SQLite main and shared-memory inodes"
            )
        }
    }

    private static func vnodeIdentities(
        targetPID: pid_t
    ) throws -> Set<Identity> {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(
            targetPID,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard estimate > 0 else {
            throw posixFailure("enumerate target vnode descriptors", code: errno)
        }

        var capacity = max(Int(estimate) / stride + 32, 64)
        for _ in 0 ..< 4 {
            var descriptors = [
                proc_fdinfo
            ](repeating: proc_fdinfo(), count: capacity)
            let byteCount = descriptors.withUnsafeMutableBytes { bytes in
                proc_pidinfo(
                    targetPID,
                    PROC_PIDLISTFDS,
                    0,
                    bytes.baseAddress,
                    Int32(bytes.count)
                )
            }
            guard byteCount >= 0 else {
                throw posixFailure("read target vnode descriptors", code: errno)
            }
            if byteCount == capacity * stride {
                capacity *= 2
                continue
            }

            var identities = Set<Identity>()
            let descriptorCount = Int(byteCount) / stride
            for descriptor in descriptors.prefix(descriptorCount)
            where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                var information = vnode_fdinfo()
                let result = withUnsafeMutablePointer(to: &information) { pointer in
                    proc_pidfdinfo(
                        targetPID,
                        descriptor.proc_fd,
                        PROC_PIDFDVNODEINFO,
                        pointer,
                        Int32(MemoryLayout<vnode_fdinfo>.size)
                    )
                }
                guard result == MemoryLayout<vnode_fdinfo>.size else {
                    continue
                }
                identities.insert(Identity(information.pvi.vi_stat))
            }
            return identities
        }
        throw contract("target vnode descriptor list did not stabilize")
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }

    private static func posixFailure(
        _ operation: String,
        code: Int32
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(
            "\(operation) failed: errno=\(code) "
                + String(cString: strerror(code))
        )
    }
}

enum DiagnosticExportPackageProbe {
    static func verify(
        scope: PinnedDiagnosticExportScope,
        ledger: HarnessLedger?
    ) throws {
        let exportPath = try scope.artifactDirectory.path
            .appending(scope.exportFileName)
        let sentinelsPath = try scope.artifactDirectory.path
            .appending(scope.sentinelsFileName)
        try verify(
            exportPath: exportPath.string,
            sentinelsPath: sentinelsPath.string,
            reader: scope.artifactReader(),
            ledger: ledger
        )
    }

    static func verify(
        exportPath: String,
        sentinelsPath: String,
        ledger: HarnessLedger?
    ) throws {
        let exportFile = try CanonicalAbsolutePath(exportPath)
        let sentinelsFile = try CanonicalAbsolutePath(sentinelsPath)
        let artifactRoot = exportFile.parent
        guard sentinelsFile.parent == artifactRoot else {
            throw contract(
                "diagnostic artifacts do not share one canonical controlled root"
            )
        }
        let reader = try DiagnosticExportFileReader(
            anchoredAtDirectoryPath: artifactRoot.string
        )
        try verify(
            exportPath: exportPath,
            sentinelsPath: sentinelsPath,
            reader: reader,
            ledger: ledger
        )
    }

    private static func verify(
        exportPath: String,
        sentinelsPath: String,
        reader: DiagnosticExportFileReader,
        ledger: HarnessLedger?
    ) throws {
        let sentinels = try loadSentinels(
            from: sentinelsPath,
            reader: reader
        )
        let first = try reader.read(
            atPath: exportPath,
            maximumByteCount: 8 * 1024 * 1024,
            requireOwnerOnlyPermissions: true
        )
        let validated = try decodeExactPackage(from: first)
        try verifyPrivacy(
            data: first,
            root: validated.root,
            package: validated.package,
            sentinels: sentinels
        )
        let package = validated.package
        let digest = SHA256.hash(data: first)
            .map { String(format: "%02x", $0) }
            .joined()
        try ledger?.pass(
            "diagnostic-package",
            "schema=1 bytes=\(first.count) sha256=\(digest) "
                + "records=\(package.records.count) "
                + "active=\(package.activeOperations.count) "
                + "capsules=\(package.operationCapsules.count) "
                + "metrics=\(package.metricAttachments.count) "
                + "sentinels=absent owner_only=true"
        )
    }

    private static func decodeExactPackage(
        from data: Data
    ) throws -> (package: DiagnosticExportPackage, root: [String: Any]) {
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            Set(root.keys) == Set([
                "manifest",
                "records",
                "activeOperations",
                "operationCapsules",
                "metricAttachments"
            ])
        else {
            throw contract("diagnostic export top-level schema is invalid")
        }
        let package: DiagnosticExportPackage
        do {
            package = try JSONDecoder().decode(
                DiagnosticExportPackage.self,
                from: data
            )
        } catch {
            throw contract("diagnostic export does not decode as the typed schema")
        }
        let typedData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            typedData = try encoder.encode(package)
        } catch {
            throw contract("diagnostic export typed schema could not be re-encoded")
        }
        guard let typedRoot = try JSONSerialization.jsonObject(with: typedData)
            as? [String: Any],
            jsonSemanticallyEqual(root, typedRoot)
        else {
            throw contract(
                "diagnostic export contains unknown or noncanonical schema fields"
            )
        }
        guard package.manifest.schemaVersion == 1,
              package.manifest.recordCount == package.records.count,
              package.manifest.activeOperationCount
              == package.activeOperations.count,
              package.manifest.operationCapsuleCount
              == package.operationCapsules.count,
              package.manifest.metricPayloadCount
              == package.metricAttachments.count
        else {
            throw contract("diagnostic export schema or manifest counts are invalid")
        }
        return (package: package, root: root)
    }

    private static func verifyPrivacy(
        data: Data,
        root: [String: Any],
        package: DiagnosticExportPackage,
        sentinels: [String]
    ) throws {
        for sentinel in sentinels {
            guard data.range(of: Data(sentinel.utf8)) == nil else {
                throw contract("diagnostic export contains a privacy sentinel")
            }
        }
        var scannedPayloads = Set<Data>()
        guard containsSentinel(
            in: root,
            sentinels: sentinels,
            scannedPayloads: &scannedPayloads
        ) == false else {
            throw contract("diagnostic export contains a logical privacy sentinel")
        }
        for attachment in package.metricAttachments {
            guard let payload = attachment.sanitizedJSON else { continue }
            if containsSentinel(
                inPayload: payload,
                sentinels: sentinels,
                scannedPayloads: &scannedPayloads
            ) {
                throw contract("diagnostic export contains a logical privacy sentinel")
            }
        }
    }

    private static func jsonSemanticallyEqual(
        _ lhs: Any,
        _ rhs: Any
    ) -> Bool {
        if let lhs = lhs as? [String: Any] {
            guard let rhs = rhs as? [String: Any] else { return false }
            guard Set(lhs.keys) == Set(rhs.keys) else { return false }
            return lhs.allSatisfy { key, value in
                guard let other = rhs[key] else { return false }
                return jsonSemanticallyEqual(value, other)
            }
        }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy {
                jsonSemanticallyEqual($0.0, $0.1)
            }
        }
        if let lhs = lhs as? String, let rhs = rhs as? String {
            return lhs == rhs
        }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
            let lhsIsBoolean = CFGetTypeID(lhs) == CFBooleanGetTypeID()
            let rhsIsBoolean = CFGetTypeID(rhs) == CFBooleanGetTypeID()
            guard lhsIsBoolean == rhsIsBoolean else { return false }
            return lhs.compare(rhs) == .orderedSame
        }
        return lhs is NSNull && rhs is NSNull
    }

    private static func containsSentinel(
        in value: Any,
        sentinels: [String],
        scannedPayloads: inout Set<Data>
    ) -> Bool {
        if let object = value as? [String: Any] {
            return object.values.contains {
                containsSentinel(
                    in: $0,
                    sentinels: sentinels,
                    scannedPayloads: &scannedPayloads
                )
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsSentinel(
                    in: $0,
                    sentinels: sentinels,
                    scannedPayloads: &scannedPayloads
                )
            }
        }
        guard let string = value as? String else { return false }
        let stringData = Data(string.utf8)
        if sentinels.contains(where: { sentinel in
            stringData.range(of: Data(sentinel.utf8)) != nil
        }) {
            return true
        }
        guard let decoded = Data(base64Encoded: string),
              decoded.isEmpty == false
        else { return false }
        return containsSentinel(
            inPayload: decoded,
            sentinels: sentinels,
            scannedPayloads: &scannedPayloads
        )
    }

    private static func containsSentinel(
        inPayload payload: Data,
        sentinels: [String],
        scannedPayloads: inout Set<Data>
    ) -> Bool {
        guard scannedPayloads.insert(payload).inserted else { return false }
        if sentinels.contains(where: { sentinel in
            payload.range(of: Data(sentinel.utf8)) != nil
        }) {
            return true
        }
        if let text = String(data: payload, encoding: .utf8) {
            if containsSentinel(
                in: text,
                sentinels: sentinels,
                scannedPayloads: &scannedPayloads
            ) {
                return true
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: payload) else {
            return false
        }
        return containsSentinel(
            in: json,
            sentinels: sentinels,
            scannedPayloads: &scannedPayloads
        )
    }

    private static func loadSentinels(
        from path: String,
        reader: DiagnosticExportFileReader
    ) throws -> [String] {
        let data = try reader.read(
            atPath: path,
            maximumByteCount: 64 * 1024,
            requireOwnerOnlyPermissions: false
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw contract("privacy sentinels are not UTF-8")
        }
        let values = text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(text.hasSuffix("\n") ? 1 : 0)
            .map(String.init)
        guard values.isEmpty == false,
              values.count <= 64,
              Set(values).count == values.count,
              values.allSatisfy({
                  $0.utf8.count >= 8
                      && $0.utf8.count <= 1024
                      && $0.unicodeScalars.allSatisfy {
                          CharacterSet.controlCharacters.contains($0) == false
                      }
              })
        else {
            throw contract("privacy sentinel set is empty, duplicate, or unbounded")
        }
        return values
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }
}
