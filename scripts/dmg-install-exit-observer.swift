import Darwin
import Foundation

enum ObserverFailure: LocalizedError {
    case invalidConfiguration
    case queueUnavailable(Int32)
    case registrationFailed(Int32)
    case timedOut(Int)
    case waitFailed(Int32, Int32)
    case unexpectedEvent(UInt32)
    case publicationFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "invalid helper exit observer configuration"
        case let .queueUnavailable(code):
            "kqueue creation failed with errno=\(code)"
        case let .registrationFailed(code):
            "EVFILT_PROC registration failed with errno=\(code)"
        case let .timedOut(seconds):
            "EVFILT_PROC timed out after \(seconds)s waiting for helper exit"
        case let .waitFailed(count, code):
            "EVFILT_PROC wait returned count=\(count) errno=\(code)"
        case let .unexpectedEvent(flags):
            "EVFILT_PROC omitted NOTE_EXIT or NOTE_EXITSTATUS: fflags=\(flags)"
        case let .publicationFailed(operation, code):
            "observer artifact \(operation) failed with errno=\(code)"
        }
    }
}

func destinationComponents(for path: String) throws -> (
    parentPath: String,
    leaf: String
) {
    let destination = URL(fileURLWithPath: path)
    let leaf = destination.lastPathComponent
    guard path.first == "/",
          leaf.isEmpty == false,
          leaf != ".",
          leaf != "..",
          leaf.contains("/") == false,
          path.unicodeScalars.allSatisfy({
              CharacterSet.controlCharacters.contains($0) == false
          })
    else {
        throw ObserverFailure.invalidConfiguration
    }
    return (destination.deletingLastPathComponent().path, leaf)
}

func writeAtomically(_ value: String, to path: String) throws {
    let (parentPath, leaf) = try destinationComponents(for: path)
    let directory = Darwin.open(
        parentPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directory >= 0 else {
        throw ObserverFailure.publicationFailed("open parent", errno)
    }
    defer { _ = Darwin.close(directory) }
    var directoryStatus = stat()
    guard fstat(directory, &directoryStatus) == 0,
          directoryStatus.st_mode & S_IFMT == S_IFDIR,
          directoryStatus.st_uid == geteuid()
    else {
        throw ObserverFailure.publicationFailed("validate parent", errno)
    }

    let temporaryLeaf = ".\(leaf).\(UUID().uuidString).tmp"
    let descriptor = temporaryLeaf.withCString { name in
        Darwin.openat(
            directory,
            name,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
    }
    guard descriptor >= 0 else {
        throw ObserverFailure.publicationFailed("create temporary", errno)
    }
    var published = false
    defer {
        _ = Darwin.close(descriptor)
        if published == false {
            temporaryLeaf.withCString { name in
                _ = Darwin.unlinkat(directory, name, 0)
            }
        }
    }

    let data = Data(value.utf8)
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            guard count > 0 else {
                throw ObserverFailure.publicationFailed("write temporary", errno)
            }
            offset += count
        }
    }
    guard fsync(descriptor) == 0 else {
        throw ObserverFailure.publicationFailed("sync temporary", errno)
    }
    let renameResult = temporaryLeaf.withCString { source in
        leaf.withCString { target in
            renameatx_np(
                directory,
                source,
                directory,
                target,
                UInt32(RENAME_EXCL)
            )
        }
    }
    guard renameResult == 0 else {
        throw ObserverFailure.publicationFailed("publish exclusive", errno)
    }
    published = true
    guard fsync(directory) == 0 else {
        throw ObserverFailure.publicationFailed("sync parent", errno)
    }
}

let environment = ProcessInfo.processInfo.environment
let resultPath = environment["NOONMARK_HELPER_EXIT_RESULT_PATH"] ?? ""
do {
    guard let mode = environment["NOONMARK_HELPER_MODE"],
          [
              "preflight",
              "exercise",
              "restart",
              "e2e-inspect",
              "e2e-menu-command",
              "diagnostic-export"
          ].contains(mode),
          let rawPID = environment["NOONMARK_HELPER_PID"],
          let pid = UInt64(rawPID), pid > 0,
          let token = environment["NOONMARK_HELPER_TOKEN"],
          UUID(uuidString: token)?.uuidString == token,
          let gatePath = environment["NOONMARK_HELPER_GATE_PATH"],
          gatePath.hasPrefix("/"),
          resultPath.hasPrefix("/"),
          let rawTimeoutSeconds = environment["NOONMARK_HELPER_EXIT_TIMEOUT_SECONDS"],
          let timeoutSeconds = Int(rawTimeoutSeconds),
          (1 ... 3600).contains(timeoutSeconds)
    else {
        throw ObserverFailure.invalidConfiguration
    }

    let queue = kqueue()
    guard queue >= 0 else {
        throw ObserverFailure.queueUnavailable(errno)
    }
    defer { close(queue) }

    var change = kevent64_s(
        ident: pid,
        filter: Int16(EVFILT_PROC),
        flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
        fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS),
        data: 0,
        udata: 0,
        ext: (0, 0)
    )
    let registrationCount = withUnsafePointer(to: &change) { pointer in
        kevent64(queue, pointer, 1, nil, 0, 0, nil)
    }
    guard registrationCount == 0 else {
        throw ObserverFailure.registrationFailed(errno)
    }

    let gate = "mode=\(mode)\n"
        + "helper_pid=\(pid)\n"
        + "launch_token=\(token)\n"
        + "observer=EVFILT_PROC+NOTE_EXITSTATUS\n"
    try writeAtomically(gate, to: gatePath)

    var event = kevent64_s()
    var timeout = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
    let eventCount = withUnsafeMutablePointer(to: &event) { eventPointer in
        withUnsafePointer(to: &timeout) { timeoutPointer in
            kevent64(queue, nil, 0, eventPointer, 1, 0, timeoutPointer)
        }
    }
    guard eventCount != 0 else {
        throw ObserverFailure.timedOut(timeoutSeconds)
    }
    guard eventCount == 1 else {
        throw ObserverFailure.waitFailed(eventCount, errno)
    }
    let requiredFlags = UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS)
    guard event.fflags & requiredFlags == requiredFlags else {
        throw ObserverFailure.unexpectedEvent(event.fflags)
    }

    let rawStatus = Int32(truncatingIfNeeded: event.data)
    let statusBits = rawStatus & 0x7F
    let normalExit = statusBits == 0
    let exitCode = normalExit ? Int((rawStatus >> 8) & 0xFF) : -1
    let signal = normalExit ? 0 : Int(statusBits)
    let result = "status=PASS\n"
        + "mode=\(mode)\n"
        + "helper_pid=\(pid)\n"
        + "launch_token=\(token)\n"
        + "fflags=0x\(String(event.fflags, radix: 16, uppercase: true))\n"
        + "raw_status=\(rawStatus)\n"
        + "normal_exit=\(normalExit)\n"
        + "exit_code=\(exitCode)\n"
        + "signal=\(signal)\n"
    try writeAtomically(result, to: resultPath)
} catch {
    let message = error.localizedDescription
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    if resultPath.hasPrefix("/") {
        try? writeAtomically("status=FAIL\nmessage=\(message)\n", to: resultPath)
    }
    FileHandle.standardError.write(Data("exit observer failed: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
