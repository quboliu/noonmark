import Darwin
import Foundation

enum ObserverFailure: LocalizedError {
    case invalidConfiguration
    case queueUnavailable(Int32)
    case registrationFailed(Int32)
    case timedOut(Int)
    case waitFailed(Int32, Int32)
    case unexpectedEvent(UInt32)

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
        }
    }
}

func writeAtomically(_ value: String, to path: String) throws {
    try Data(value.utf8).write(
        to: URL(fileURLWithPath: path),
        options: .atomic
    )
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
