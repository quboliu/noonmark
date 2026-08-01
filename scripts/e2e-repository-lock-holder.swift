import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lock holder failed: \(message)\n".utf8))
    exit(EX_SOFTWARE)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    fail("expected LOCK_PATH READY_PATH UUID")
}

let lockPath = arguments[0]
let readyPath = arguments[1]
let token = arguments[2]
guard lockPath.hasPrefix("/"),
      readyPath.hasPrefix("/"),
      lockPath.contains("/artifacts/e2e-diagnostic-closure/"),
      readyPath.contains("/artifacts/e2e-diagnostic-closure/"),
      lockPath.hasSuffix("/.repository.lock"),
      UUID(uuidString: token)?.uuidString == token,
      FileManager.default.fileExists(atPath: readyPath) == false
else {
    fail("unsafe or malformed arguments")
}

let descriptor = lockPath.withCString {
    Darwin.open(
        $0,
        O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
        mode_t(S_IRUSR | S_IWUSR)
    )
}

guard descriptor >= 0 else {
    fail("open errno=\(errno)")
}

defer { _ = Darwin.close(descriptor) }
guard flock(descriptor, LOCK_EX) == 0 else {
    fail("flock errno=\(errno)")
}

defer { _ = flock(descriptor, LOCK_UN) }

let ready = "status=ready\npid=\(getpid())\ntoken=\(token)\nlock=\(lockPath)\n"
do {
    try ready.write(
        to: URL(fileURLWithPath: readyPath),
        atomically: true,
        encoding: .utf8
    )
} catch {
    fail("publish ready: \(error.localizedDescription)")
}

while true {
    _ = pause()
}
