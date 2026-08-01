import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
enum NoonmarkDMGInstallHarness {
    private static let expectedDMGValidationBundleIdentifier =
        "app.noonmark.mac.dmg-validation"
    private static let expectedE2EBundleIdentifier = "app.noonmark.mac.e2e"

    enum Mode: String {
        case preflight
        case exercise
        case restart
        case e2eInspect = "e2e-inspect"
        case e2eMenuCommand = "e2e-menu-command"
        case diagnosticExport = "diagnostic-export"
    }

    struct Configuration {
        let mode: Mode
        let pid: pid_t
        let appPath: String
        let taskTitle: String
        let ledgerPath: String
        let launchToken: String
        let startGatePath: String
        let windowNumber: CGWindowID
        let windowTitle: String
        let expectationsPath: String
        let menuTitle: String
        let menuItemTitle: String
        let completionPath: String
        let targetProfile: String
        let databasePath: String
        let repositoryLockPath: String
        let exportPath: String
        let sentinelsPath: String

        static func parse(_ arguments: [String]) throws -> Self {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                guard key.hasPrefix("--"), index + 1 < arguments.count else {
                    throw HarnessFailure.invalidArguments(
                        "expected --name value pairs; received \(arguments)"
                    )
                }
                guard values.updateValue(arguments[index + 1], forKey: key) == nil else {
                    throw HarnessFailure.invalidArguments("duplicate option \(key)")
                }
                index += 2
            }
            let allowed = Set([
                "--mode",
                "--pid",
                "--app-path",
                "--task-title",
                "--ledger",
                "--launch-token",
                "--start-gate",
                "--window-number",
                "--window-title",
                "--expectations",
                "--menu-title",
                "--menu-item-title",
                "--completion",
                "--target-profile",
                "--database",
                "--repository-lock",
                "--export-path",
                "--sentinels"
            ])
            let unknown = Set(values.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                throw HarnessFailure.invalidArguments(
                    "unknown options: \(unknown.sorted().joined(separator: ", "))"
                )
            }
            guard let rawMode = values["--mode"], let mode = Mode(rawValue: rawMode),
                  let ledgerPath = values["--ledger"], ledgerPath.isEmpty == false,
                  let rawLaunchToken = values["--launch-token"],
                  let launchToken = UUID(uuidString: rawLaunchToken)?.uuidString,
                  launchToken == rawLaunchToken,
                  let startGatePath = values["--start-gate"],
                  Self.isAbsoluteSingleLinePath(startGatePath)
            else {
                throw HarnessFailure.invalidArguments(
                    "required: --mode preflight|exercise|restart|e2e-inspect|"
                        + "e2e-menu-command --ledger PATH --launch-token UUID "
                        + "--start-gate ABSOLUTE_PATH"
                )
            }
            if mode == .preflight {
                guard values.count == 4 else {
                    throw HarnessFailure.invalidArguments(
                        "preflight accepts only --mode preflight --ledger PATH "
                            + "--launch-token UUID --start-gate ABSOLUTE_PATH"
                    )
                }
                return Self(
                    mode: mode,
                    pid: 0,
                    appPath: "",
                    taskTitle: "",
                    ledgerPath: ledgerPath,
                    launchToken: launchToken,
                    startGatePath: startGatePath,
                    windowNumber: 0,
                    windowTitle: "",
                    expectationsPath: "",
                    menuTitle: "",
                    menuItemTitle: "",
                    completionPath: "",
                    targetProfile: "",
                    databasePath: "",
                    repositoryLockPath: "",
                    exportPath: "",
                    sentinelsPath: ""
                )
            }
            if mode == .e2eInspect {
                guard values.count == 9,
                      let rawPID = values["--pid"],
                      let parsedPID = Int32(rawPID),
                      parsedPID > 0,
                      let appPath = values["--app-path"],
                      Self.isAbsoluteSingleLinePath(appPath),
                      let rawWindowNumber = values["--window-number"],
                      let windowNumber = CGWindowID(rawWindowNumber),
                      windowNumber > 0,
                      let windowTitle = values["--window-title"],
                      Self.isNonemptySingleLineText(windowTitle),
                      let expectationsPath = values["--expectations"],
                      Self.isAbsoluteSingleLinePath(expectationsPath)
                else {
                    throw HarnessFailure.invalidArguments(
                        "e2e-inspect requires exact --pid, --app-path, "
                            + "--window-number, --window-title and --expectations"
                    )
                }
                return Self(
                    mode: mode,
                    pid: parsedPID,
                    appPath: appPath,
                    taskTitle: "",
                    ledgerPath: ledgerPath,
                    launchToken: launchToken,
                    startGatePath: startGatePath,
                    windowNumber: windowNumber,
                    windowTitle: windowTitle,
                    expectationsPath: expectationsPath,
                    menuTitle: "",
                    menuItemTitle: "",
                    completionPath: "",
                    targetProfile: "",
                    databasePath: "",
                    repositoryLockPath: "",
                    exportPath: "",
                    sentinelsPath: ""
                )
            }
            if mode == .e2eMenuCommand {
                guard values.count == 11,
                      let rawPID = values["--pid"],
                      let parsedPID = Int32(rawPID),
                      parsedPID > 0,
                      let appPath = values["--app-path"],
                      Self.isAbsoluteSingleLinePath(appPath),
                      let rawWindowNumber = values["--window-number"],
                      let windowNumber = CGWindowID(rawWindowNumber),
                      windowNumber > 0,
                      let windowTitle = values["--window-title"],
                      Self.isNonemptySingleLineText(windowTitle),
                      let menuTitle = values["--menu-title"],
                      let menuItemTitle = values["--menu-item-title"],
                      let completionPath = values["--completion"],
                      Self.isAbsoluteSingleLinePath(completionPath),
                      Self.isSupportedHelpCommand(
                          menuTitle: menuTitle,
                          menuItemTitle: menuItemTitle
                      )
                else {
                    throw HarnessFailure.invalidArguments(
                        "e2e-menu-command requires exact --pid, --app-path, "
                            + "--window-number, --window-title, --menu-title and "
                            + "--menu-item-title for the localized Help command, "
                            + "plus --completion ABSOLUTE_PATH"
                    )
                }
                return Self(
                    mode: mode,
                    pid: parsedPID,
                    appPath: appPath,
                    taskTitle: "",
                    ledgerPath: ledgerPath,
                    launchToken: launchToken,
                    startGatePath: startGatePath,
                    windowNumber: windowNumber,
                    windowTitle: windowTitle,
                    expectationsPath: "",
                    menuTitle: menuTitle,
                    menuItemTitle: menuItemTitle,
                    completionPath: completionPath,
                    targetProfile: "",
                    databasePath: "",
                    repositoryLockPath: "",
                    exportPath: "",
                    sentinelsPath: ""
                )
            }
            if mode == .diagnosticExport {
                guard values.count == 13,
                      let rawPID = values["--pid"],
                      let parsedPID = Int32(rawPID),
                      parsedPID > 0,
                      let appPath = values["--app-path"],
                      Self.isAbsoluteSingleLinePath(appPath),
                      let rawWindowNumber = values["--window-number"],
                      let windowNumber = CGWindowID(rawWindowNumber),
                      windowNumber > 0,
                      let windowTitle = values["--window-title"],
                      Self.isNonemptySingleLineText(windowTitle),
                      let targetProfile = values["--target-profile"],
                      ["e2e", "dmg-validation"].contains(targetProfile),
                      let databasePath = values["--database"],
                      Self.isAbsoluteSingleLinePath(databasePath),
                      databasePath.hasSuffix(".sqlite"),
                      let repositoryLockPath = values["--repository-lock"],
                      Self.isAbsoluteSingleLinePath(repositoryLockPath),
                      repositoryLockPath.hasSuffix("/.repository.lock"),
                      let exportPath = values["--export-path"],
                      Self.isAbsoluteSingleLinePath(exportPath),
                      exportPath.hasSuffix(".noonmarkdiagnostics"),
                      let sentinelsPath = values["--sentinels"],
                      Self.isAbsoluteSingleLinePath(sentinelsPath),
                      Set([
                          databasePath,
                          repositoryLockPath,
                          exportPath,
                          sentinelsPath
                      ]).count == 4
                else {
                    throw HarnessFailure.invalidArguments(
                        "diagnostic-export requires exact target identity, "
                            + "--target-profile e2e|dmg-validation, --database, "
                            + "--repository-lock, --export-path and --sentinels"
                    )
                }
                return Self(
                    mode: mode,
                    pid: parsedPID,
                    appPath: appPath,
                    taskTitle: "",
                    ledgerPath: ledgerPath,
                    launchToken: launchToken,
                    startGatePath: startGatePath,
                    windowNumber: windowNumber,
                    windowTitle: windowTitle,
                    expectationsPath: "",
                    menuTitle: "",
                    menuItemTitle: "",
                    completionPath: "",
                    targetProfile: targetProfile,
                    databasePath: databasePath,
                    repositoryLockPath: repositoryLockPath,
                    exportPath: exportPath,
                    sentinelsPath: sentinelsPath
                )
            }
            guard
                  values.count == 7,
                  let rawPID = values["--pid"], let parsedPID = Int32(rawPID), parsedPID > 0,
                  let appPath = values["--app-path"], appPath.isEmpty == false,
                  let taskTitle = values["--task-title"],
                  taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  taskTitle == taskTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                  taskTitle.unicodeScalars.allSatisfy({
                      CharacterSet.controlCharacters.contains($0) == false
                  })
            else {
                throw HarnessFailure.invalidArguments(
                    "required: --mode exercise|restart --pid PID --app-path APP "
                        + "--task-title TITLE --ledger PATH"
                )
            }
            return Self(
                mode: mode,
                pid: parsedPID,
                appPath: appPath,
                taskTitle: taskTitle,
                ledgerPath: ledgerPath,
                launchToken: launchToken,
                startGatePath: startGatePath,
                windowNumber: 0,
                windowTitle: "",
                expectationsPath: "",
                menuTitle: "",
                menuItemTitle: "",
                completionPath: "",
                targetProfile: "",
                databasePath: "",
                repositoryLockPath: "",
                exportPath: "",
                sentinelsPath: ""
            )
        }

        private static func isSupportedHelpCommand(
            menuTitle: String,
            menuItemTitle: String
        ) -> Bool {
            (menuTitle == "帮助" && menuItemTitle == "晷迹使用帮助")
                || (menuTitle == "Help" && menuItemTitle == "Noonmark Help")
        }

        private static func isNonemptySingleLineText(_ text: String) -> Bool {
            text.isEmpty == false && text.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0) == false
            }
        }

        private static func isAbsoluteSingleLinePath(_ path: String) -> Bool {
            guard path.hasPrefix("/"),
                  path.unicodeScalars.allSatisfy({
                      CharacterSet.controlCharacters.contains($0) == false
                  })
            else {
                return false
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path == path
        }
    }

    enum HarnessFailure: LocalizedError {
        case invalidArguments(String)
        case targetIdentity(String)
        case contract(String)

        var errorDescription: String? {
            switch self {
            case let .invalidArguments(reason):
                "Invalid harness arguments: \(reason)"
            case let .targetIdentity(reason):
                "Validation target identity failed: \(reason)"
            case let .contract(reason):
                "Validation UI contract failed: \(reason)"
            }
        }
    }

    static func main() {
        var ledger: HarnessLedger?
        do {
            let configuration = try Configuration.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            ledger = try HarnessLedger(path: configuration.ledgerPath)
            try ledger?.pass(
                "arguments",
                configuration.argumentDetail
            )
            let helperPID = getpid()
            try ledger?.pass(
                "process",
                "mode=\(configuration.mode.rawValue) helper_pid=\(helperPID) "
                    + "launch_token=\(configuration.launchToken)"
            )
            if configuration.mode == .e2eMenuCommand {
                try CompletionArtifact.validateDestination(
                    path: configuration.completionPath
                )
            }
            try waitForExitObserver(
                configuration: configuration,
                helperPID: helperPID
            )
            try ledger?.pass(
                "exit-observer",
                "helper_pid=\(helperPID) launch_token=\(configuration.launchToken) "
                    + "observer=EVFILT_PROC+NOTE_EXITSTATUS"
            )

            let input = try WindowServerInputDriver()
            try ledger?.pass(
                "permissions",
                "AXIsProcessTrusted=true CGPreflightPostEventAccess=true"
            )
            if configuration.mode == .preflight {
                try ledger?.pass("complete", "mode=preflight")
                exit(EXIT_SUCCESS)
            }

            let target = try validateTarget(
                configuration: configuration,
                ledger: ledger
            )
            let runner = Runner(
                configuration: configuration,
                target: target,
                input: input,
                ledger: ledger
            )
            switch configuration.mode {
            case .preflight:
                throw HarnessFailure.contract("preflight reached the validation runner")
            case .exercise:
                try runner.exercise()
            case .restart:
                try runner.verifyRestart()
            case .e2eInspect:
                try runner.inspectE2EAccessibility()
            case .e2eMenuCommand:
                try runner.performE2EMenuCommand()
                try CompletionArtifact.publish(
                    configuration: configuration,
                    helperPID: helperPID
                )
                try ledger?.pass(
                    "completion",
                    "path=\(configuration.completionPath) atomic=true "
                        + "exact=true lines=7"
                )
            case .diagnosticExport:
                let locks = try DiagnosticExportLocks(
                    databasePath: configuration.databasePath,
                    repositoryLockPath: configuration.repositoryLockPath
                )
                try locks.proveContention(step: "before-export", ledger: ledger)
                try runner.performDiagnosticExport()
                try locks.proveContention(step: "after-export", ledger: ledger)
                try DiagnosticExportPackageProbe.verify(
                    exportPath: configuration.exportPath,
                    sentinelsPath: configuration.sentinelsPath,
                    ledger: ledger
                )
            }
            try ledger?.pass("complete", "mode=\(configuration.mode.rawValue)")
            exit(EXIT_SUCCESS)
        } catch {
            let message = error.localizedDescription
            ledger?.fail("fatal", message)
            FileHandle.standardError.write(Data("harness failed: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func waitForExitObserver(
        configuration: Configuration,
        helperPID: pid_t
    ) throws {
        let gateURL = URL(fileURLWithPath: configuration.startGatePath)
        let expected = "mode=\(configuration.mode.rawValue)\n"
            + "helper_pid=\(helperPID)\n"
            + "launch_token=\(configuration.launchToken)\n"
            + "observer=EVFILT_PROC+NOTE_EXITSTATUS\n"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))

        repeat {
            var status = stat()
            if lstat(configuration.startGatePath, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFREG else {
                    throw HarnessFailure.contract(
                        "exit observer gate is not a regular file"
                    )
                }
                let actual: String
                do {
                    actual = try String(contentsOf: gateURL, encoding: .utf8)
                } catch {
                    throw HarnessFailure.contract(
                        "exit observer gate could not be read: \(error.localizedDescription)"
                    )
                }
                guard actual == expected else {
                    throw HarnessFailure.contract(
                        "exit observer gate did not match this helper process"
                    )
                }
                return
            }
            if errno != ENOENT {
                throw HarnessFailure.contract(
                    "exit observer gate could not be inspected: errno=\(errno)"
                )
            }
            usleep(25000)
        } while clock.now < deadline

        throw HarnessFailure.contract(
            "timed out waiting for the verified exit observer gate"
        )
    }

    private static func validateTarget(
        configuration: Configuration,
        ledger: HarnessLedger?
    ) throws -> AXTarget {
        let expectedBundleIdentifier = switch configuration.mode {
        case .e2eInspect, .e2eMenuCommand:
            expectedE2EBundleIdentifier
        case .diagnosticExport:
            configuration.targetProfile == "e2e"
                ? expectedE2EBundleIdentifier
                : expectedDMGValidationBundleIdentifier
        case .preflight, .exercise, .restart:
            expectedDMGValidationBundleIdentifier
        }
        guard let running = NSRunningApplication(
            processIdentifier: configuration.pid
        ), running.isTerminated == false else {
            throw HarnessFailure.targetIdentity(
                "pid \(configuration.pid) is not a running application"
            )
        }
        guard running.bundleIdentifier == expectedBundleIdentifier else {
            throw HarnessFailure.targetIdentity(
                "bundle id was \(running.bundleIdentifier ?? "nil"), expected "
                    + expectedBundleIdentifier
            )
        }
        guard let bundleURL = running.bundleURL else {
            throw HarnessFailure.targetIdentity("running application has no bundle URL")
        }
        let expectedURL = URL(fileURLWithPath: configuration.appPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let actualURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard actualURL.path == expectedURL.path else {
            throw HarnessFailure.targetIdentity(
                "bundle path was \(actualURL.path), expected \(expectedURL.path)"
            )
        }
        let target = AXTarget(pid: configuration.pid)
        try target.waitUntilFrontmost()
        guard running.isActive else {
            throw HarnessFailure.targetIdentity("target app is not frontmost")
        }
        guard target.windows().isEmpty == false else {
            throw HarnessFailure.targetIdentity("target app exposes no AX windows")
        }
        try ledger?.pass(
            "target",
            "bundle=\(expectedBundleIdentifier) path=\(actualURL.path) "
                + "frontmost=true windows=\(target.windows().count)"
        )
        return target
    }
}

private extension NoonmarkDMGInstallHarness.Configuration {
    var argumentDetail: String {
        if mode == .preflight { return "mode=preflight" }
        if mode == .e2eInspect {
            return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath) "
                + "window_number=\(windowNumber) window=\(windowTitle) "
                + "expectations=\(expectationsPath)"
        }
        if mode == .e2eMenuCommand {
            return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath) "
                + "window_number=\(windowNumber) window=\(windowTitle) "
                + "menu=\(menuTitle) item=\(menuItemTitle) "
                + "completion=\(completionPath)"
        }
        if mode == .diagnosticExport {
            return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath) "
                + "window_number=\(windowNumber) window=\(windowTitle) "
                + "target_profile=\(targetProfile) database=\(databasePath) "
                + "repository_lock=\(repositoryLockPath) export=\(exportPath) "
                + "sentinels=\(sentinelsPath)"
        }
        return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath)"
    }
}

private enum CompletionArtifact {
    static func validateDestination(path: String) throws {
        let destination = URL(fileURLWithPath: path)
        var destinationStatus = stat()
        let destinationResult = destination.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &destinationStatus)
        }
        guard destinationResult != Int32.min else {
            throw contract("completion path has no filesystem representation")
        }
        if destinationResult == 0 {
            throw contract("completion already exists: \(path)")
        }
        guard errno == ENOENT else {
            throw posixFailure("inspect completion destination", code: errno)
        }

        let parent = destination.deletingLastPathComponent()
        var parentStatus = stat()
        let parentResult = parent.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &parentStatus)
        }
        guard parentResult != Int32.min else {
            throw contract("completion parent has no filesystem representation")
        }
        guard parentResult == 0 else {
            throw posixFailure("inspect completion parent", code: errno)
        }
        guard parentStatus.st_mode & S_IFMT == S_IFDIR else {
            throw contract("completion parent is not a real directory: \(parent.path)")
        }
    }

    static func publish(
        configuration: NoonmarkDMGInstallHarness.Configuration,
        helperPID: pid_t
    ) throws {
        try validateDestination(path: configuration.completionPath)
        let expected = [
            "status=complete",
            "launch_token=\(configuration.launchToken)",
            "helper_pid=\(helperPID)",
            "target_pid=\(configuration.pid)",
            "window_number=\(configuration.windowNumber)",
            "menu_title=\(configuration.menuTitle)",
            "menu_item_title=\(configuration.menuItemTitle)"
        ].joined(separator: "\n") + "\n"
        let expectedData = Data(expected.utf8)
        let destination = URL(fileURLWithPath: configuration.completionPath)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent)."
                    + "\(configuration.launchToken).\(helperPID).tmp"
            )
        try requireAbsent(temporary, description: "completion temporary file")

        let descriptor = try openExclusive(temporary)
        var descriptorIsOpen = true
        var temporaryIsPresent = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryIsPresent {
                temporary.withUnsafeFileSystemRepresentation { pointer in
                    guard let pointer else { return }
                    _ = Darwin.unlink(pointer)
                }
            }
        }

        try write(expectedData, to: descriptor)
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixFailure("set completion permissions", code: errno)
        }
        try synchronize(descriptor, description: "completion temporary file")
        descriptorIsOpen = false
        guard Darwin.close(descriptor) == 0 else {
            throw posixFailure("close completion temporary file", code: errno)
        }

        try renameExclusive(temporary, destination)
        temporaryIsPresent = false
        try synchronizeDirectory(destination.deletingLastPathComponent())
        try verify(destination, equals: expectedData)
    }

    private static func requireAbsent(
        _ url: URL,
        description: String
    ) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &status)
        }
        guard result != Int32.min else {
            throw contract("\(description) has no filesystem representation")
        }
        if result == 0 {
            throw contract("\(description) already exists: \(url.path)")
        }
        guard errno == ENOENT else {
            throw posixFailure("inspect \(description)", code: errno)
        }
    }

    private static func openExclusive(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return Darwin.open(
                pointer,
                O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor != Int32.min else {
            throw contract("completion temporary path has no filesystem representation")
        }
        guard descriptor >= 0 else {
            throw posixFailure("create completion temporary file", code: errno)
        }
        return descriptor
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = try data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    let code = errno
                    if code == EINTR { return -1 }
                    throw posixFailure("write completion temporary file", code: code)
                }
                return result
            }
            if count == -1 { continue }
            guard count > 0 else {
                throw contract("completion temporary write made no progress")
            }
            offset += count
        }
    }

    private static func synchronize(
        _ descriptor: Int32,
        description: String
    ) throws {
        while fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw posixFailure("synchronize \(description)", code: code)
        }
    }

    private static func renameExclusive(_ source: URL, _ destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePointer in
            destination.withUnsafeFileSystemRepresentation { destinationPointer in
                guard let sourcePointer, let destinationPointer else {
                    return Int32.min
                }
                return renamex_np(
                    sourcePointer,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result != Int32.min else {
            throw contract("completion publish path has no filesystem representation")
        }
        guard result == 0 else {
            throw posixFailure("publish completion without overwrite", code: errno)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return Darwin.open(
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor != Int32.min else {
            throw contract("completion parent has no filesystem representation")
        }
        guard descriptor >= 0 else {
            throw posixFailure("open completion parent", code: errno)
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
        }
        try synchronize(descriptor, description: "completion parent")
        descriptorIsOpen = false
        guard Darwin.close(descriptor) == 0 else {
            throw posixFailure("close completion parent", code: errno)
        }
    }

    private static func verify(_ url: URL, equals expected: Data) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32.min }
            return lstat(pointer, &status)
        }
        guard result != Int32.min else {
            throw contract("published completion has no filesystem representation")
        }
        guard result == 0 else {
            throw posixFailure("inspect published completion", code: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size == expected.count,
              let first = try? Data(contentsOf: url),
              let second = try? Data(contentsOf: url),
              first == expected,
              second == expected
        else {
            throw contract("published completion did not match its exact seven-line payload")
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
        .contract("\(operation) failed: errno=\(code) \(String(cString: strerror(code)))")
    }
}

private struct E2EAccessibilityExpectation {
    static let recordPrefix = "classification_remove_button="
    static let expectedTaskTitle =
        "Coordinate the launch readiness review with accessibility owners"
    static let expectedTagNames = Set([
        "Accessibility",
        "Launch Readiness"
    ])

    let identifier: String
    let label: String
    let tagName: String

    static func load(from path: String) throws -> [Self] {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              status.st_size <= 16384
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E AX expectations are not a bounded regular file"
            )
        }
        let url = URL(fileURLWithPath: path)
        let initial = try Data(contentsOf: url)
        let current = try Data(contentsOf: url)
        guard initial == current,
              let text = String(data: initial, encoding: .utf8),
              text.split(separator: "\n").count(where: {
                  $0 == "classification_remove_button_count=2"
              }) == 1
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E AX expectations changed while being read or lost their count"
            )
        }
        let records = try text.split(separator: "\n").compactMap { line -> Self? in
            guard line.hasPrefix(recordPrefix) else { return nil }
            let payload = line.dropFirst(recordPrefix.count)
            let fields = payload.split(
                separator: "\t",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2 else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "E2E AX expectation is not identifier-tab-label"
                )
            }
            let identifier = String(fields[0])
            let label = String(fields[1])
            let components = identifier.split(separator: ".")
            guard components.count == 5,
                  components[0] == "classification",
                  components[1] == "editor",
                  components[2] == "remove-label",
                  UUID(uuidString: String(components[3])) != nil,
                  UUID(uuidString: String(components[4])) != nil,
                  label.hasPrefix("Remove the tag “"),
                  label.hasSuffix("” from “\(expectedTaskTitle)”"),
                  label.unicodeScalars.allSatisfy({
                      CharacterSet.controlCharacters.contains($0) == false
                  })
            else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "E2E AX expectation identity or English label is invalid"
                )
            }
            let tagName = label
                .dropFirst("Remove the tag “".count)
                .dropLast("” from “\(expectedTaskTitle)”".count)
            return Self(
                identifier: identifier,
                label: label,
                tagName: String(tagName)
            )
        }
        guard records.count == 2,
              Set(records.map(\.identifier)).count == 2,
              Set(records.map(\.tagName)) == expectedTagNames,
              Set(records.map {
                  $0.identifier.split(separator: ".")[3]
              }).count == 1
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E AX expectations are not the exact two selected-task tag controls"
            )
        }
        return records.sorted { $0.identifier < $1.identifier }
    }
}

private struct CorrelatedE2EWindow {
    let element: AXUIElement
    let frame: CGRect
    let cgTitle: String?
    let initialWindows: [AXUIElement]
}

private final class Runner {
    private let configuration: NoonmarkDMGInstallHarness.Configuration
    private let target: AXTarget
    private let input: WindowServerInputDriver
    private let ledger: HarnessLedger?

    init(
        configuration: NoonmarkDMGInstallHarness.Configuration,
        target: AXTarget,
        input: WindowServerInputDriver,
        ledger: HarnessLedger?
    ) {
        self.configuration = configuration
        self.target = target
        self.input = input
        self.ledger = ledger
    }

    func exercise() throws {
        try assertMainWindow()
        try openAndVerifySettings()
        try openQuickEntryAndCreateTask()
        try assertTaskTitleVisible(step: "exercise-title-visible")
        try quitThroughAppMenu()
    }

    func verifyRestart() throws {
        try assertMainWindow()
        try assertTaskTitleVisible(step: "restart-title-visible")
        try quitThroughAppMenu()
    }

    func inspectE2EAccessibility() throws {
        let expectations = try E2EAccessibilityExpectation.load(
            from: configuration.expectationsPath
        )
        let correlated = try correlatedE2EWindow(requireFocused: false)
        let cgWindowFrame = correlated.frame
        let initialWindows = correlated.initialWindows
        let window = correlated.element
        let windowFrame = correlated.frame
        try ledger?.pass(
            "e2e-window",
            "window_number=\(configuration.windowNumber) "
                + "cg_title=\(correlated.cgTitle == nil ? "private" : "matched") "
                + "ax_title=\(configuration.windowTitle) cg_frame=\(cgWindowFrame) "
                + "ax_frame=\(windowFrame) correlation=unique exact=true"
        )

        let descendants = try target.strictDescendants(of: window)
        let removeButtons = descendants.filter {
            $0.identifier?.hasPrefix(
                "classification.editor.remove-label."
            ) == true
        }
        guard removeButtons.count == 2 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E selected detail exposed \(removeButtons.count) remove-tag AX controls, expected 2"
            )
        }

        var evidence: [String] = []
        for expectation in expectations {
            let matches = descendants.filter {
                $0.identifier == expectation.identifier
            }
            guard matches.count == 1 else {
                let observed = removeButtons.map { button in
                    let identifier = button.identifier ?? "nil"
                    let title = button.title ?? "nil"
                    let description = button.description ?? "nil"
                    return "id=\(identifier) role=\(button.role) "
                        + "title=\(title) description=\(description)"
                }
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "E2E AX identifier \(expectation.identifier) "
                        + "matched \(matches.count) controls; observed=\(observed)"
                )
            }
            let match = matches[0]
            let publishedLabels = Set(
                [match.title, match.description]
                    .compactMap { $0 }
                    .filter { $0.isEmpty == false }
            )
            let frame = try target.requiredFrame(
                match,
                description: expectation.identifier
            )
            guard match.role == kAXButtonRole as String,
                  publishedLabels.contains(expectation.label),
                  match.enabled == true,
                  match.hidden != true,
                  windowFrame.contains(frame)
            else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "E2E AX control mismatch id=\(expectation.identifier) "
                        + "role=\(match.role) labels=\(publishedLabels.sorted()) "
                        + "enabled=\(match.enabled.map(String.init) ?? "nil") "
                        + "hidden=\(match.hidden.map(String.init) ?? "nil") "
                        + "frame=\(frame) window=\(windowFrame)"
                )
            }
            evidence.append(
                "tag=\(expectation.tagName) id=\(expectation.identifier) "
                    + "role=AXButton enabled=true "
                    + "hidden=\(match.hidden.map(String.init) ?? "nil") frame=\(frame)"
            )
        }

        let currentWindows = target.windows()
        let currentCGWindow = try exactCGWindow()
        guard currentWindows.count == initialWindows.count,
              currentWindows.contains(where: { CFEqual($0, window) }),
              target.string(window, kAXTitleAttribute as String)
              == configuration.windowTitle,
              target.frame(window) == cgWindowFrame,
              currentCGWindow.frame == cgWindowFrame
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E AX target window identity changed during inspection"
            )
        }
        try ledger?.pass(
            "e2e-remove-buttons",
            "count=2 unique=true \(evidence.joined(separator: " | "))"
        )
    }

    func performE2EMenuCommand() throws {
        let correlated = try correlatedE2EWindow(requireFocused: true)
        let mainWindow = correlated.element
        let initialWindows = correlated.initialWindows
        let preexistingHelpWindows = exactWindows(titled: configuration.menuItemTitle)
        guard preexistingHelpWindows.isEmpty else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Help window was already present before the external menu command: "
                    + "count=\(preexistingHelpWindows.count)"
            )
        }
        try ledger?.pass(
            "e2e-window",
            "window_number=\(configuration.windowNumber) "
                + "cg_title=\(correlated.cgTitle == nil ? "private" : "matched") "
                + "ax_title=\(configuration.windowTitle) cg_frame=\(correlated.frame) "
                + "ax_frame=\(correlated.frame) correlation=unique exact=true "
                + "focused=true"
        )

        let menuBar = try target.menuBar()
        let topLevelMatches = target.directMatches(
            in: menuBar,
            roles: [kAXMenuBarItemRole as String],
            titles: [configuration.menuTitle]
        )
        guard topLevelMatches.count == 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "top-level Help menu count was \(topLevelMatches.count), expected 1"
            )
        }
        let topLevel = topLevelMatches[0]
        guard topLevel.enabled == true, topLevel.hidden != true else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "top-level Help menu was not visible and enabled"
            )
        }
        let topLevelFrame = try target.requiredFrame(
            topLevel,
            description: "top-level Help menu"
        )
        try input.click(frame: topLevelFrame)
        try ledger?.pass(
            "menu-bar",
            "title=\(configuration.menuTitle) role=AXMenuBarItem enabled=true "
                + "hidden=\(topLevel.hidden.map(String.init) ?? "nil") "
                + "frame=\(topLevelFrame) source=cghidEventTap"
        )

        let menuItem: AXTarget.Match = try target.wait(
            description: "the exact visible Help menu command"
        ) {
            try visibleMenuItem(in: menuBar)
        }
        let menuItemFrame = try target.requiredFrame(
            menuItem,
            description: "Help menu command"
        )
        try ledger?.pass(
            "menu-item",
            "title=\(configuration.menuItemTitle) role=AXMenuItem enabled=true "
                + "hidden=\(menuItem.hidden.map(String.init) ?? "nil") "
                + "frame=\(menuItemFrame) exact=true"
        )
        try input.click(frame: menuItemFrame)

        let helpWindow: AXUIElement = try target.wait(
            description: "one independent focused Help window after its menu closes"
        ) {
            let candidates = exactWindows(titled: configuration.menuItemTitle)
            guard candidates.count <= 1 else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "duplicate Help windows after menu command: count=\(candidates.count)"
                )
            }
            guard let candidate = candidates.first else { return nil }
            guard initialWindows.contains(where: { CFEqual($0, candidate) }) == false else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "Help command reused a preexisting target window"
                )
            }
            guard try visibleMenuItem(in: menuBar) == nil else { return nil }
            guard let focused = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            ), CFEqual(focused, candidate) else {
                return nil
            }
            return candidate
        }
        let helpFrame = try target.requiredFrame(
            helpWindow,
            description: "independent Help window"
        )
        guard CFEqual(helpWindow, mainWindow) == false,
              helpFrame.width >= 520,
              helpFrame.height >= 420,
              target.windows().contains(where: { CFEqual($0, mainWindow) })
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Help was not a separate minimum-size window: frame=\(helpFrame)"
            )
        }
        let helpCGWindow: (number: CGWindowID, title: String?) = try target.wait(
            description: "the exact onscreen CG Help window"
        ) {
            try onscreenCGWindow(
                frame: helpFrame,
                title: configuration.menuItemTitle
            )
        }
        try ledger?.pass(
            "menu-command",
            "menu=\(configuration.menuTitle) item=\(configuration.menuItemTitle) "
                + "source=cghidEventTap clicks=2 menu_closed=true independent=true "
                + "focused=true help_window_number=\(helpCGWindow.number) "
                + "cg_title=\(helpCGWindow.title == nil ? "private" : "matched") "
                + "help_frame=\(helpFrame)"
        )
    }

    func performDiagnosticExport() throws {
        let correlated = try correlatedE2EWindow(requireFocused: true)
        let exportURL = URL(fileURLWithPath: configuration.exportPath)
        try requireDiagnosticExportDestination(exportURL)
        try ledger?.pass(
            "diagnostic-window",
            "window_number=\(configuration.windowNumber) "
                + "frame=\(correlated.frame) focused=true exact=true"
        )

        let exportItem = try revealMenuItemWithoutShortcut(
            topLevelTitles: ["帮助", "Help"],
            itemTitles: ["导出诊断资料…", "Export Diagnostics…"],
            step: "diagnostic-menu"
        )
        try input.click(
            frame: target.requiredFrame(
                exportItem,
                description: "Export Diagnostics menu item"
            )
        )

        let preview = try target.wait(
            description: "the exact diagnostic export preview"
        ) {
            try uniqueDiagnosticWindow(
                titleTexts: ["导出前预览", "Preview Before Export"],
                buttonTitles: [
                    ["选择保存位置…", "Choose Save Location…"],
                    ["取消", "Cancel"]
                ],
                description: "diagnostic preview"
            )
        }
        let previewDescendants = try target.strictDescendants(of: preview)
        let previewText = previewDescendants.compactMap { match in
            match.title
                ?? target.string(match.element, kAXValueAttribute as String)
                ?? match.description
        }.joined(separator: "\n")
        guard previewText.contains("Schema v1"),
              previewText.contains("预计导出")
              || previewText.contains("Estimated export"),
              previewText.contains("不会自动发送")
              || previewText.contains("Nothing is sent automatically")
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic preview omitted schema, size, or consent disclosure"
            )
        }
        let continueButton = try uniqueMatch(
            in: preview,
            roles: [kAXButtonRole as String],
            titles: ["选择保存位置…", "Choose Save Location…"],
            identifier: nil,
            description: "diagnostic preview continue button"
        )
        let focusedPreview: AXUIElement = try target.wait(
            description: "focused diagnostic preview"
        ) {
            guard let focused = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            ), CFEqual(focused, preview) else { return nil }
            return focused
        }
        guard CFEqual(focusedPreview, preview),
              let defaultButton = target.element(
                  preview,
                  kAXDefaultButtonAttribute as String
              ),
              CFEqual(defaultButton, continueButton.element),
              continueButton.enabled == true,
              continueButton.hidden != true
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic preview continue control was not the focused default button"
            )
        }
        try ledger?.pass(
            "diagnostic-preview",
            "schema=1 size=visible consent=visible focused=true default=exact"
        )
        try input.keyStroke(virtualKey: 36)

        let savePanel: AXUIElement
        do {
            savePanel = try target.wait(
                description: "the app-owned diagnostic save panel"
            ) {
                try uniqueDiagnosticWindow(
                    titleTexts: [
                        "导出晷迹诊断资料",
                        "Export Noonmark Diagnostics"
                    ],
                    buttonTitles: [
                        ["存储", "保存", "Save"],
                        ["取消", "Cancel"]
                    ],
                    description: "diagnostic save panel"
                )
            }
        } catch {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic save panel AX mismatch; observed="
                    + diagnosticWindowSummary()
            )
        }
        try input.keyStroke(
            virtualKey: 5,
            flags: [.maskCommand, .maskShift]
        )
        let locationField: AXUIElement = try target.wait(
            description: "save-panel location field"
        ) {
            guard let focused = target.element(
                target.application,
                kAXFocusedUIElementAttribute as String
            ),
                target.string(focused, kAXRoleAttribute as String)
                == kAXTextFieldRole as String
            else { return nil }
            return focused
        }
        let exportParent = exportURL.deletingLastPathComponent().path
        try input.typeUnicode(exportParent)
        _ = try target.wait(description: "exact save-panel location value") {
            target.string(locationField, kAXValueAttribute as String)
            == exportParent ? true : nil
        }
        try input.keyStroke(virtualKey: 36)

        let basename = exportURL.lastPathComponent
        let nameField: AXTarget.Match = try target.wait(
            description: "diagnostic save-panel filename field"
        ) {
            let fields = try target.strictMatches(
                in: savePanel,
                roles: [kAXTextFieldRole as String]
            ).filter { match in
                let value = target.string(
                    match.element,
                    kAXValueAttribute as String
                ) ?? ""
                return value.hasPrefix("Noonmark-Diagnostics-")
                    && value.hasSuffix(".noonmarkdiagnostics")
            }
            guard fields.count <= 1 else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "diagnostic save panel exposed duplicate filename fields"
                )
            }
            return fields.first
        }
        try input.click(
            frame: target.requiredFrame(
                nameField,
                description: "diagnostic filename field"
            ),
            clickCount: 3
        )
        try input.typeUnicode(basename)
        _ = try target.wait(description: "exact diagnostic export filename") {
            target.string(nameField.element, kAXValueAttribute as String)
            == basename ? true : nil
        }
        let saveButton = try uniqueMatch(
            in: savePanel,
            roles: [kAXButtonRole as String],
            titles: ["存储", "保存", "Save"],
            identifier: nil,
            description: "diagnostic save button"
        )
        try input.click(
            frame: target.requiredFrame(
                saveButton,
                description: "diagnostic save button"
            )
        )

        let _: Bool = try target.wait(
            seconds: 15,
            description: "diagnostic export file and success toast"
        ) {
            guard FileManager.default.fileExists(atPath: exportURL.path) else {
                return nil
            }
            let successToast = target.windows().flatMap {
                target.descendants(of: $0)
            }.contains { match in
                guard match.identifier == "app.toast" else { return false }
                let text = match.title
                    ?? target.string(match.element, kAXValueAttribute as String)
                    ?? match.description
                return text == "诊断资料已导出"
                    || text == "Diagnostics exported"
            }
            return successToast ? true : nil
        }
        try ledger?.pass(
            "diagnostic-export-ui",
            "menu=physical preview=physical save_panel=physical "
                + "path=selected toast=visible source=cghidEventTap"
        )
    }

    private func requireDiagnosticExportDestination(_ url: URL) throws {
        var status = stat()
        let result = lstat(url.path, &status)
        guard result == -1, errno == ENOENT else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic export destination already exists"
            )
        }
        var parentStatus = stat()
        guard lstat(url.deletingLastPathComponent().path, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic export parent is not a real directory"
            )
        }
    }

    private func uniqueDiagnosticWindow(
        titleTexts: Set<String>,
        buttonTitles: [Set<String>],
        description: String
    ) throws -> AXUIElement? {
        var candidates: [AXUIElement] = []
        for window in target.windows() {
            let descendants = try target.strictDescendants(of: window)
            let textValues = Set(descendants.compactMap { match in
                match.title
                    ?? target.string(match.element, kAXValueAttribute as String)
                    ?? match.description
            })
            guard textValues.isDisjoint(with: titleTexts) == false else {
                continue
            }
            var hasEveryButton = true
            for titles in buttonTitles {
                let matches = descendants.filter {
                    $0.role == kAXButtonRole as String
                        && titles.contains($0.title ?? "")
                }
                guard matches.count <= 1 else {
                    throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                        "\(description) duplicated a required button"
                    )
                }
                if matches.isEmpty { hasEveryButton = false }
            }
            if hasEveryButton { candidates.append(window) }
        }
        guard candidates.count <= 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "duplicate \(description) windows: count=\(candidates.count)"
            )
        }
        return candidates.first
    }

    private func diagnosticWindowSummary() -> String {
        target.windows().prefix(8).map { window in
            let windowTitle = target.string(
                window,
                kAXTitleAttribute as String
            ) ?? "nil"
            let children = target.descendants(
                of: window,
                maximumDepth: 8,
                maximumCount: 256
            ).compactMap { match -> String? in
                guard match.role == kAXButtonRole as String
                    || match.role == kAXTextFieldRole as String
                    || match.role == kAXStaticTextRole as String
                else { return nil }
                let value = target.string(
                    match.element,
                    kAXValueAttribute as String
                )
                let text = match.title ?? value ?? match.description ?? "nil"
                return "\(match.role):\(text.prefix(160))"
            }.prefix(32).joined(separator: ",")
            return "window=\(windowTitle){\(children)}"
        }.joined(separator: " | ")
    }

    private func revealMenuItemWithoutShortcut(
        topLevelTitles: Set<String>,
        itemTitles: Set<String>,
        step: String
    ) throws -> AXTarget.Match {
        try target.waitUntilFrontmost()
        let menuBar = try target.menuBar()
        let topLevel = try uniqueMatch(
            in: menuBar,
            roles: [kAXMenuBarItemRole as String],
            titles: topLevelTitles,
            identifier: nil,
            description: "top-level diagnostic menu"
        )
        try input.click(
            frame: target.requiredFrame(
                topLevel,
                description: "top-level diagnostic menu"
            )
        )
        let item = try target.wait(description: "diagnostic menu command") {
            try uniqueMatchIfPresent(
                in: menuBar,
                roles: [kAXMenuItemRole as String],
                titles: itemTitles,
                identifier: nil,
                description: "diagnostic menu command"
            )
        }
        guard target.boolean(item.element, kAXEnabledAttribute as String) == true,
              target.string(
                  item.element,
                  kAXMenuItemCmdCharAttribute as String
              ) == nil
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic menu command was disabled or gained a shortcut"
            )
        }
        try ledger?.pass(
            step,
            "title=\(item.title ?? "unknown") shortcut=none source=cghidEventTap"
        )
        return item
    }

    private func correlatedE2EWindow(
        requireFocused: Bool
    ) throws -> CorrelatedE2EWindow {
        let cgWindow = try exactCGWindow()
        let initialWindows = target.windows()
        let matchingWindows = initialWindows.filter { window in
            target.string(window, kAXRoleAttribute as String)
                == kAXWindowRole as String
                && target.string(window, kAXTitleAttribute as String)
                == configuration.windowTitle
                && target.frame(window) == cgWindow.frame
        }
        guard matchingWindows.count == 1 else {
            let observedWindows = initialWindows.map { window in
                let role = target.string(window, kAXRoleAttribute as String) ?? "nil"
                let title = target.string(window, kAXTitleAttribute as String) ?? "nil"
                let frame = target.frame(window).map { String(describing: $0) } ?? "nil"
                return "role=\(role) title=\(title) frame=\(frame)"
            }
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E AX target window count was \(matchingWindows.count), expected 1; "
                    + "CG frame=\(cgWindow.frame) observed=\(observedWindows)"
            )
        }
        let window = matchingWindows[0]
        let frame = try target.requiredFrame(
            window,
            description: "E2E main window"
        )
        guard frame.width >= 960, frame.height >= 720 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E main window is below its minimum size: \(frame)"
            )
        }
        if requireFocused {
            guard let focused = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            ), CFEqual(focused, window) else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "the configured E2E main window was not the focused AX window"
                )
            }
        }
        return CorrelatedE2EWindow(
            element: window,
            frame: frame,
            cgTitle: cgWindow.title,
            initialWindows: initialWindows
        )
    }

    private func exactWindows(titled title: String) -> [AXUIElement] {
        target.windows().filter { window in
            target.string(window, kAXRoleAttribute as String)
                == kAXWindowRole as String
                && target.string(window, kAXTitleAttribute as String) == title
        }
    }

    private func visibleMenuItem(
        in menuBar: AXUIElement
    ) throws -> AXTarget.Match? {
        let exactMatches = try target.strictMatches(
            in: menuBar,
            roles: [kAXMenuItemRole as String],
            titles: [configuration.menuItemTitle]
        )
        let matches = exactMatches.filter { match in
            match.hidden != true
                && (try? target.requiredFrame(
                    match,
                    description: "visible Help menu command"
                )) != nil
        }
        guard matches.count <= 1 else {
            let observed = matches.map { match in
                let frame = match.frame.map { String(describing: $0) } ?? "nil"
                return "role=\(match.role) title=\(match.title ?? "nil") "
                    + "enabled=\(match.enabled.map(String.init) ?? "nil") "
                    + "hidden=\(match.hidden.map(String.init) ?? "nil") "
                    + "frame=\(frame) "
                    + "identity=\(CFHash(match.element))"
            }
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "exact Help menu command was duplicated: count=\(matches.count) "
                    + "observed=\(observed)"
            )
        }
        guard let match = matches.first else {
            return nil
        }
        guard match.enabled == true else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "exact Help menu command was visible but disabled"
            )
        }
        return match
    }

    private func onscreenCGWindow(
        frame: CGRect,
        title: String
    ) throws -> (number: CGWindowID, title: String?)? {
        guard let records = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "onscreen CG window list was unavailable"
            )
        }
        var candidates: [(number: CGWindowID, title: String?)] = []
        for record in records {
            let ownerPID = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let number = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let recordTitle = record[kCGWindowName as String] as? String
            let layer = (record[kCGWindowLayer as String] as? NSNumber)?.intValue
            let isOnscreen = (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
            let alpha = (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            guard ownerPID == configuration.pid,
                  let number,
                  recordTitle == nil || recordTitle == title,
                  layer == 0,
                  isOnscreen == true,
                  let alpha,
                  alpha > 0,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  CGRect(x: x, y: y, width: width, height: height) == frame
            else {
                continue
            }
            candidates.append((number: number, title: recordTitle))
        }
        guard candidates.count <= 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Help AX frame correlated with duplicate CG windows: count=\(candidates.count)"
            )
        }
        return candidates.first
    }

    private func exactCGWindow() throws -> (frame: CGRect, title: String?) {
        guard let records = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            configuration.windowNumber
        ) as? [[String: Any]], records.count == 1
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CGWindowNumber \(configuration.windowNumber) did not resolve exactly once"
            )
        }
        let record = records[0]
        let ownerPID = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let windowNumber = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        let title = record[kCGWindowName as String] as? String
        let layer = (record[kCGWindowLayer as String] as? NSNumber)?.intValue
        let isOnscreen = (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        let alpha = (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
        guard let bounds = record[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CGWindowNumber \(configuration.windowNumber) has no complete bounds"
            )
        }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        guard ownerPID == configuration.pid,
              windowNumber == configuration.windowNumber,
              title == nil || title == configuration.windowTitle,
              layer == 0,
              isOnscreen == true,
              let alpha,
              alpha > 0,
              frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CG window identity mismatch "
                    + "pid=\(ownerPID.map { String($0) } ?? "nil") "
                    + "number=\(windowNumber.map { String($0) } ?? "nil") "
                    + "title=\(title ?? "nil") "
                    + "layer=\(layer.map { String($0) } ?? "nil") "
                    + "onscreen=\(isOnscreen.map { String($0) } ?? "nil") "
                    + "alpha=\(alpha.map { String($0) } ?? "nil") frame=\(frame)"
            )
        }
        return (frame: frame, title: title)
    }

    private func assertMainWindow() throws {
        let windows = target.windows()
        guard windows.contains(where: { window in
            let role = target.string(window, kAXRoleAttribute as String)
            guard role == kAXWindowRole as String,
                  let frame = target.requiredFrameOrNil(window)
            else {
                return false
            }
            return frame.width >= 960 && frame.height >= 720
        }) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "no validation main window with a usable native window role"
            )
        }
        try ledger?.pass("main-window", "native AXWindow is visible")
    }

    private func openAndVerifySettings() throws {
        let preexistingWindows = target.windows()
        let settingsItem = try revealMenuItem(
            topLevelTitles: ["晷迹", "Noonmark"],
            itemTitles: ["设置…", "Settings…"],
            expectedKey: ",",
            step: "settings-menu"
        )
        try input.click(
            frame: target.requiredFrame(settingsItem, description: "Settings menu item")
        )

        let settingsWindow = try target.wait(
            description: "independent Settings window and AX anchors"
        ) {
            try uniqueWindow(
                containing: ["settings.sidebar", "settings.content"],
                description: "Settings"
            )
        }
        guard preexistingWindows.contains(where: { CFEqual($0, settingsWindow) }) == false else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Settings reused a preexisting validation window"
            )
        }
        let settingsFrame = try target.requiredFrame(
            settingsWindow,
            description: "Settings window"
        )
        guard settingsFrame.width >= 680, settingsFrame.height >= 500 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Settings frame was \(settingsFrame), expected at least 680x500"
            )
        }
        let sidebar = try uniqueMatch(
            in: settingsWindow,
            identifier: "settings.sidebar",
            description: "Settings sidebar"
        )
        let content = try uniqueMatch(
            in: settingsWindow,
            identifier: "settings.content",
            description: "Settings content"
        )
        guard let sidebarFrame = sidebar.frame,
              let contentFrame = content.frame,
              sidebarFrame.intersects(contentFrame) == false
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Settings sidebar/content anchors are absent or geometrically overlapping"
            )
        }
        try ledger?.pass(
            "settings-window",
            "independent=true window=\(settingsFrame) sidebar=\(sidebarFrame) "
                + "content=\(contentFrame)"
        )

        guard let closeButton = target.element(
            settingsWindow,
            kAXCloseButtonAttribute as String
        ) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Settings exposes no close button"
            )
        }
        try input.click(
            frame: target.requiredFrame(closeButton, description: "Settings close button")
        )
        _ = try target.wait(description: "Settings window to close") {
            try uniqueWindow(
                containing: ["settings.sidebar", "settings.content"],
                description: "Settings"
            ) == nil ? true : nil
        }
        try ledger?.pass("settings-close", "closed with real WindowServer click")
    }

    private func openQuickEntryAndCreateTask() throws {
        let quickEntryItem = try revealMenuItem(
            topLevelTitles: ["文件", "File"],
            itemTitles: ["快速记录…", "Quick Entry…"],
            expectedKey: "n",
            step: "quick-entry-menu"
        )
        try input.click(
            frame: target.requiredFrame(quickEntryItem, description: "Quick Entry menu item")
        )

        let panel = try target.wait(description: "Quick Entry panel and AX anchors") {
            try uniqueWindow(
                containing: ["quick-entry.field", "quick-entry.add"],
                description: "Quick Entry"
            )
        }
        let field = try uniqueMatch(
            in: panel,
            identifier: "quick-entry.field",
            description: "Quick Entry field"
        )
        _ = try uniqueMatch(
            in: panel,
            identifier: "quick-entry.add",
            description: "Quick Entry Add button"
        )
        guard target.boolean(field.element, kAXEnabledAttribute as String) == true else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "Quick Entry field/add anchors are incomplete or disabled"
            )
        }
        try input.click(
            frame: target.requiredFrame(field, description: "Quick Entry field")
        )
        try input.typeUnicode(configuration.taskTitle)
        _ = try target.wait(description: "Quick Entry Unicode field value") {
            target.string(field.element, kAXValueAttribute as String) == configuration.taskTitle
                ? true
                : nil
        }
        let enabledAdd: AXTarget.Match = try target.wait(
            description: "enabled Quick Entry Add button"
        ) { () -> AXTarget.Match? in
            let refreshed = try uniqueMatchIfPresent(
                in: panel,
                roles: nil,
                titles: nil,
                identifier: "quick-entry.add",
                description: "Quick Entry Add button"
            )
            guard let refreshed,
                  target.boolean(refreshed.element, kAXEnabledAttribute as String) == true
            else {
                return nil
            }
            return refreshed
        }
        try ledger?.pass(
            "quick-entry-input",
            "value=\(configuration.taskTitle) source=cghidEventTap"
        )
        try input.click(
            frame: target.requiredFrame(enabledAdd, description: "Quick Entry Add button")
        )
        _ = try target.wait(description: "Quick Entry panel to dismiss") {
            try uniqueWindow(
                containing: ["quick-entry.field", "quick-entry.add"],
                description: "Quick Entry"
            ) == nil ? true : nil
        }
        try ledger?.pass("quick-entry-add", "panel dismissed after real click")
    }

    private func assertTaskTitleVisible(step: String) throws {
        let matchCount: Int = try target.wait(
            description: "persisted task title in the validation AX tree"
        ) {
            let count = target.windows().reduce(into: 0) { count, window in
                count += target.descendants(of: window).filter { match in
                    Self.containsTaskTitle(match.title, configuration.taskTitle)
                        || Self.containsTaskTitle(
                            target.string(match.element, kAXValueAttribute as String),
                            configuration.taskTitle
                        )
                        || Self.containsTaskTitle(
                            target.string(match.element, kAXDescriptionAttribute as String),
                            configuration.taskTitle
                        )
                }.count
            }
            return count > 0 ? count : nil
        }
        try ledger?.pass(
            step,
            "title=\(configuration.taskTitle) visibleAXMatches=\(matchCount)"
        )
    }

    private func quitThroughAppMenu() throws {
        let quitItem = try revealMenuItem(
            topLevelTitles: ["晷迹", "Noonmark"],
            itemTitles: ["退出晷迹", "Quit Noonmark"],
            expectedKey: "q",
            step: "quit-menu"
        )
        try input.click(
            frame: target.requiredFrame(quitItem, description: "Quit menu item")
        )
        let pid = configuration.pid
        _ = try target.wait(seconds: 12, description: "validation app to terminate") {
            kill(pid, 0) == -1 && errno == ESRCH ? true : nil
        }
        try ledger?.pass("quit", "terminated via real App menu click")
    }

    private func revealMenuItem(
        topLevelTitles: Set<String>,
        itemTitles: Set<String>,
        expectedKey: String,
        step: String
    ) throws -> AXTarget.Match {
        try target.waitUntilFrontmost()
        let menuBar = try target.menuBar()
        let topLevel = try uniqueMatch(
            in: menuBar,
            roles: [kAXMenuBarItemRole as String],
            titles: topLevelTitles,
            identifier: nil,
            description: "top-level menu \(topLevelTitles.sorted())"
        )
        try input.click(
            frame: target.requiredFrame(topLevel, description: "top-level menu")
        )
        let item = try target.wait(description: "menu item \(itemTitles.sorted())") {
            try uniqueMatchIfPresent(
                in: menuBar,
                roles: [kAXMenuItemRole as String],
                titles: itemTitles,
                identifier: nil,
                description: "menu item \(itemTitles.sorted())"
            )
        }
        guard target.boolean(item.element, kAXEnabledAttribute as String) == true else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "menu item \(item.title ?? "unknown") is disabled"
            )
        }
        let key = target.string(item.element, kAXMenuItemCmdCharAttribute as String)
        let modifiers = target.integer(
            item.element,
            kAXMenuItemCmdModifiersAttribute as String
        )
        guard key?.lowercased() == expectedKey.lowercased(),
              let modifiers,
              modifiers == 0
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "menu item shortcut was key=\(key ?? "nil") modifiers=\(modifiers.map(String.init) ?? "nil")"
            )
        }
        try ledger?.pass(
            step,
            "title=\(item.title ?? "unknown") shortcut=Command-\(expectedKey)"
        )
        return item
    }

    private func uniqueMatch(
        in root: AXUIElement,
        roles: Set<String>? = nil,
        titles: Set<String>? = nil,
        identifier: String? = nil,
        description: String
    ) throws -> AXTarget.Match {
        guard let match = try uniqueMatchIfPresent(
            in: root,
            roles: roles,
            titles: titles,
            identifier: identifier,
            description: description
        ) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "missing \(description)"
            )
        }
        return match
    }

    private func uniqueMatchIfPresent(
        in root: AXUIElement,
        roles: Set<String>? = nil,
        titles: Set<String>? = nil,
        identifier: String? = nil,
        description: String
    ) throws -> AXTarget.Match? {
        let matches = target.matches(
            in: root,
            roles: roles,
            titles: titles,
            identifier: identifier
        )
        guard matches.count <= 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "duplicate \(description): count=\(matches.count)"
            )
        }
        return matches.first
    }

    private func uniqueWindow(
        containing identifiers: Set<String>,
        description: String
    ) throws -> AXUIElement? {
        var candidates: [AXUIElement] = []
        for window in target.windows() {
            let descendants = target.descendants(of: window)
            var containsEveryIdentifier = true
            for identifier in identifiers {
                let count = descendants.count { $0.identifier == identifier }
                guard count <= 1 else {
                    throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                        "duplicate \(description) identifier \(identifier): count=\(count)"
                    )
                }
                if count == 0 { containsEveryIdentifier = false }
            }
            if containsEveryIdentifier { candidates.append(window) }
        }
        guard candidates.count <= 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "duplicate \(description) windows: count=\(candidates.count)"
            )
        }
        return candidates.first
    }

    private static func containsTaskTitle(_ candidate: String?, _ title: String) -> Bool {
        candidate?.range(of: title, options: [.literal]) != nil
    }
}

private extension AXTarget {
    func requiredFrameOrNil(_ element: AXUIElement) -> CGRect? {
        try? requiredFrame(element, description: "window")
    }
}
