import AppKit
import ApplicationServices
import Darwin
import Foundation
import NoonmarkMacE2ESupport

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
        case e2eOpenPanel = "e2e-open-panel"
        case diagnosticExport = "diagnostic-export"
        case diagnosticExportScope = "diagnostic-export-scope"
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
        let openPanelReadyPath: String
        let openPanelReady: OpenPanelPhysicalInputReady?

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
                "--ready",
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
            guard let rawMode = values["--mode"], let mode = Mode(rawValue: rawMode)
            else {
                throw HarnessFailure.invalidArguments(
                    "required: --mode preflight|exercise|restart|e2e-inspect|"
                        + "e2e-menu-command|diagnostic-export|"
                        + "e2e-open-panel|"
                        + "diagnostic-export-scope"
                )
            }
            if mode == .diagnosticExportScope {
                return try parseDiagnosticExportScope(values)
            }
            guard let ledgerPath = values["--ledger"], ledgerPath.isEmpty == false,
                  let rawLaunchToken = values["--launch-token"],
                  let launchToken = UUID(uuidString: rawLaunchToken)?.uuidString,
                  launchToken == rawLaunchToken,
                  let startGatePath = values["--start-gate"],
                  Self.isAbsoluteSingleLinePath(startGatePath)
            else {
                throw HarnessFailure.invalidArguments(
                    "required: --mode preflight|exercise|restart|e2e-inspect|"
                        + "e2e-menu-command|diagnostic-export --ledger PATH "
                        + "e2e-open-panel|"
                        + "--launch-token UUID "
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
                    sentinelsPath: "",
                    openPanelReadyPath: "",
                    openPanelReady: nil
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
                    sentinelsPath: "",
                    openPanelReadyPath: "",
                    openPanelReady: nil
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
                    sentinelsPath: "",
                    openPanelReadyPath: "",
                    openPanelReady: nil
                )
            }
            if mode == .e2eOpenPanel {
                guard values.count == 6,
                      let readyPath = values["--ready"],
                      Self.isAbsoluteSingleLinePath(readyPath),
                      let completionPath = values["--completion"],
                      Self.isAbsoluteSingleLinePath(completionPath),
                      readyPath != completionPath
                else {
                    throw HarnessFailure.invalidArguments(
                        "e2e-open-panel requires exact --ready and --completion paths"
                    )
                }
                let readyURL = URL(fileURLWithPath: readyPath)
                let completionURL = URL(fileURLWithPath: completionPath)
                let ready = try OpenPanelPhysicalInputProtocolFile.readReady(
                    from: readyURL
                )
                guard ready.launchToken == launchToken,
                      readyURL.deletingLastPathComponent()
                      == completionURL.deletingLastPathComponent(),
                      readyURL.lastPathComponent
                      == "\(ready.interactionLabel).ready.json",
                      completionURL.lastPathComponent
                      == "\(ready.interactionLabel).completion.json",
                      let parsedPID = Int32(exactly: ready.targetPID),
                      let windowNumber = CGWindowID(exactly: ready.panelWindowNumber)
                else {
                    throw HarnessFailure.invalidArguments(
                        "e2e-open-panel ready identity did not bind every argument"
                    )
                }
                return Self(
                    mode: mode,
                    pid: parsedPID,
                    appPath: ready.appPath,
                    taskTitle: "",
                    ledgerPath: ledgerPath,
                    launchToken: launchToken,
                    startGatePath: startGatePath,
                    windowNumber: windowNumber,
                    windowTitle: ready.panelTitle,
                    expectationsPath: "",
                    menuTitle: "",
                    menuItemTitle: "",
                    completionPath: completionPath,
                    targetProfile: "",
                    databasePath: "",
                    repositoryLockPath: "",
                    exportPath: "",
                    sentinelsPath: "",
                    openPanelReadyPath: readyPath,
                    openPanelReady: ready
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
                let configuration = Self(
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
                    sentinelsPath: sentinelsPath,
                    openPanelReadyPath: "",
                    openPanelReady: nil
                )
                try DiagnosticExportScopeContract.validate(configuration)
                return configuration
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
                sentinelsPath: "",
                openPanelReadyPath: "",
                openPanelReady: nil
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
            (try? CanonicalAbsolutePath(path))?.string == path
        }

        private static func parseDiagnosticExportScope(
            _ values: [String: String]
        ) throws -> Self {
            guard values.count == 3,
                  let appPath = values["--app-path"],
                  isAbsoluteSingleLinePath(appPath),
                  let targetProfile = values["--target-profile"],
                  ["e2e", "dmg-validation"].contains(targetProfile)
            else {
                throw HarnessFailure.invalidArguments(
                    "diagnostic-export-scope accepts only exact --app-path "
                        + "and --target-profile e2e|dmg-validation"
                )
            }
            return Self(
                mode: .diagnosticExportScope,
                pid: 0,
                appPath: appPath,
                taskTitle: "",
                ledgerPath: "",
                launchToken: "",
                startGatePath: "",
                windowNumber: 0,
                windowTitle: "",
                expectationsPath: "",
                menuTitle: "",
                menuItemTitle: "",
                completionPath: "",
                targetProfile: targetProfile,
                databasePath: "",
                repositoryLockPath: "",
                exportPath: "",
                sentinelsPath: "",
                openPanelReadyPath: "",
                openPanelReady: nil
            )
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
        let arguments = Array(CommandLine.arguments.dropFirst())
        if SQLiteByteRangeLockHolder.isChildInvocation(arguments) {
            SQLiteByteRangeLockHolder.runSpawnedChild(arguments)
        }
        var ledger: HarnessLedger?
        do {
            let configuration = try Configuration.parse(arguments)
            if configuration.mode == .diagnosticExportScope {
                let manifest = try DiagnosticExportScopeContract.scopeManifest(
                    configuration
                )
                FileHandle.standardOutput.write(Data(manifest.utf8))
                exit(EXIT_SUCCESS)
            }
            let diagnosticScope: PinnedDiagnosticExportScope? =
                if configuration.mode == .diagnosticExport {
                    try DiagnosticExportScopeContract.pin(configuration)
                } else {
                    nil
                }
            if let diagnosticScope {
                ledger = try HarnessLedger(
                    directory: diagnosticScope.controlDirectory,
                    fileName: diagnosticScope.ledgerFileName,
                    requireNew: true,
                    expectedPassSteps: HarnessLedgerContract.expectedPassSteps(
                        for: configuration.mode
                    )
                )
            } else {
                ledger = try HarnessLedger(
                    path: configuration.ledgerPath,
                    expectedPassSteps: HarnessLedgerContract.expectedPassSteps(
                        for: configuration.mode
                    )
                )
            }
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
                helperPID: helperPID,
                diagnosticScope: diagnosticScope
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
                ledger: ledger,
                diagnosticScope: diagnosticScope
            )
            try runConfiguredMode(
                configuration: configuration,
                helperPID: helperPID,
                runner: runner,
                ledger: ledger,
                diagnosticScope: diagnosticScope
            )
            try ledger?.pass("complete", "mode=\(configuration.mode.rawValue)")
            exit(EXIT_SUCCESS)
        } catch {
            let message = error.localizedDescription
            ledger?.fail("fatal", message)
            FileHandle.standardError.write(Data("harness failed: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func runConfiguredMode(
        configuration: Configuration,
        helperPID: pid_t,
        runner: Runner,
        ledger: HarnessLedger?,
        diagnosticScope: PinnedDiagnosticExportScope?
    ) throws {
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
        case .e2eOpenPanel:
            let buttonTitle = try runner.performE2EOpenPanelPhysicalInput()
            guard let ready = configuration.openPanelReady else {
                throw HarnessFailure.contract(
                    "E2E Open panel runner lost its parsed ready payload"
                )
            }
            let completion = try OpenPanelPhysicalInputCompletion(
                launchToken: configuration.launchToken,
                helperPID: Int(helperPID),
                targetPID: Int(configuration.pid),
                panelWindowNumber: Int(configuration.windowNumber),
                selectedPath: ready.selectedPath,
                interactionLabel: ready.interactionLabel,
                buttonTitle: buttonTitle,
                leftButtonUp: true
            )
            try OpenPanelPhysicalInputProtocolFile.publish(
                completion,
                to: URL(fileURLWithPath: configuration.completionPath)
            )
            try ledger?.pass(
                "completion",
                "path=\(configuration.completionPath) atomic=true exact=true "
                    + "schema=1 left_button_up=true"
            )
        case .diagnosticExport:
            try runDiagnosticExport(
                configuration: configuration,
                runner: runner,
                ledger: ledger,
                scope: diagnosticScope
            )
        case .diagnosticExportScope:
            throw HarnessFailure.contract(
                "diagnostic-export-scope reached the validation runner"
            )
        }
    }

    private static func runDiagnosticExport(
        configuration: Configuration,
        runner: Runner,
        ledger: HarnessLedger?,
        scope: PinnedDiagnosticExportScope?
    ) throws {
        guard let scope else {
            throw HarnessFailure.contract(
                "diagnostic-export scope was not pinned"
            )
        }
        let locks = try DiagnosticExportLocks(
            scope: scope,
            targetPID: configuration.pid
        )
        try locks.proveContention(step: "before-export", ledger: ledger)
        try runner.performDiagnosticExport()
        try locks.proveContention(step: "after-export", ledger: ledger)
        try DiagnosticExportPackageProbe.verify(
            scope: scope,
            ledger: ledger
        )
        try locks.release(ledger: ledger)
    }

    private static func waitForExitObserver(
        configuration: Configuration,
        helperPID: pid_t,
        diagnosticScope: PinnedDiagnosticExportScope?
    ) throws {
        let expected = "mode=\(configuration.mode.rawValue)\n"
            + "helper_pid=\(helperPID)\n"
            + "launch_token=\(configuration.launchToken)\n"
            + "observer=EVFILT_PROC+NOTE_EXITSTATUS\n"
        let diagnosticGate: (
            reader: DiagnosticExportFileReader,
            path: String
        )? = try diagnosticScope.map { scope in
            (
                reader: scope.controlReader(),
                path: try scope.controlDirectory.path
                    .appending(scope.startGateFileName)
                    .string
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))

        repeat {
            if let diagnosticGate {
                if let data = try diagnosticGate.reader.readIfPresent(
                    atPath: diagnosticGate.path,
                    maximumByteCount: 4 * 1024,
                    requireOwnerOnlyPermissions: false
                ) {
                    guard String(data: data, encoding: .utf8) == expected else {
                        throw HarnessFailure.contract(
                            "exit observer gate did not match this helper process"
                        )
                    }
                    return
                }
                usleep(25000)
                continue
            }

            let gateURL = URL(fileURLWithPath: configuration.startGatePath)
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
        case .e2eInspect, .e2eMenuCommand, .e2eOpenPanel:
            expectedE2EBundleIdentifier
        case .diagnosticExport:
            configuration.targetProfile == "e2e"
                ? expectedE2EBundleIdentifier
                : expectedDMGValidationBundleIdentifier
        case .preflight, .exercise, .restart, .diagnosticExportScope:
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
        let activationEvidence = try TargetForegroundOwnership(
            expected: .init(
                processIdentifier: configuration.pid,
                bundleIdentifier: expectedBundleIdentifier,
                bundleURL: expectedURL
            ),
            application: running,
            accessibility: target
        ).establish()
        try ledger?.pass(
            "activation",
            "bundle=\(expectedBundleIdentifier) path=\(actualURL.path) "
                + activationEvidence.ledgerDetail
        )
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
        if mode == .e2eOpenPanel {
            return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath) "
                + "window_number=\(windowNumber) window=\(windowTitle) "
                + "ready=\(openPanelReadyPath) completion=\(completionPath)"
        }
        if mode == .diagnosticExport {
            return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath) "
                + "window_number=\(windowNumber) window=\(windowTitle) "
                + "target_profile=\(targetProfile) database=\(databasePath) "
                + "repository_lock=\(repositoryLockPath) export=\(exportPath) "
                + "sentinels=\(sentinelsPath)"
        }
        if mode == .diagnosticExportScope {
            return "mode=\(mode.rawValue) app=\(appPath) "
                + "target_profile=\(targetProfile)"
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

private enum PhysicalMenuShortcut: Equatable {
    case none
    case command(String)
}

private struct PhysicalMenuSelection {
    let topLevelTitle: String
    let topLevelFrame: CGRect
    let itemTitle: String
    let itemFrame: CGRect
    let itemHidden: Bool?
}

private final class Runner {
    private let configuration: NoonmarkDMGInstallHarness.Configuration
    private let target: AXTarget
    private let input: WindowServerInputDriver
    private let ledger: HarnessLedger?
    private let diagnosticScope: PinnedDiagnosticExportScope?

    init(
        configuration: NoonmarkDMGInstallHarness.Configuration,
        target: AXTarget,
        input: WindowServerInputDriver,
        ledger: HarnessLedger?,
        diagnosticScope: PinnedDiagnosticExportScope?
    ) {
        self.configuration = configuration
        self.target = target
        self.input = input
        self.ledger = ledger
        self.diagnosticScope = diagnosticScope
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

        let menuSelection = try selectPhysicalMenuCommand(
            topLevelTitles: [configuration.menuTitle],
            itemTitles: [configuration.menuItemTitle],
            shortcut: .none,
            description: "Help menu command"
        )
        try ledger?.pass(
            "menu-bar",
            "title=\(configuration.menuTitle) role=AXMenuBarItem enabled=true "
                + "frame=\(menuSelection.topLevelFrame) source=cghidEventTap"
        )
        try ledger?.pass(
            "menu-item",
            "title=\(configuration.menuItemTitle) role=AXMenuItem enabled=true "
                + "hidden=\(menuSelection.itemHidden.map(String.init) ?? "nil") "
                + "frame=\(menuSelection.itemFrame) exact=true pre_mouse_down=exact "
                + "menu_closed=true left_button_up=true"
        )

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
        guard let helpWindowNumber = target.windowNumber(helpWindow) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "the exact AX Help window exposed no WindowServer identity"
            )
        }
        let helpCGWindow: (number: CGWindowID, title: String?) = try target.wait(
            description: "the exact onscreen CG Help window"
        ) {
            try onscreenCGWindow(
                windowNumber: helpWindowNumber,
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

    func performE2EOpenPanelPhysicalInput() throws -> String {
        guard let expectedReady = configuration.openPanelReady else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E Open panel mode had no parsed ready payload"
            )
        }
        let cgWindow = try exactOpenPanelCGWindow()
        let panelMatches = target.windows().filter { window in
            target.string(window, kAXRoleAttribute as String)
                == kAXWindowRole as String
                && target.string(window, kAXTitleAttribute as String)
                == configuration.windowTitle
                && target.windowNumber(window) == configuration.windowNumber
                && target.frame(window) == cgWindow.frame
        }
        guard panelMatches.count == 1,
              let panel = panelMatches.first,
              let focusedWindow = target.element(
                  target.application,
                  kAXFocusedWindowAttribute as String
              ),
              CFEqual(focusedWindow, panel)
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E Open panel was not the unique focused exact WindowServer window"
            )
        }
        try ledger?.pass(
            "open-panel",
            "window_number=\(configuration.windowNumber) "
                + "title=\(configuration.windowTitle) focused=true "
                + "windowserver_owner_pid=\(cgWindow.ownerPID) "
                + "layer=\(expectedReady.panelLayer) "
                + "cg_frame=\(cgWindow.frame) ax_cg_correlation=exact"
        )

        let buttonMatches = try target.strictDescendants(of: panel).filter { match in
            match.role == kAXButtonRole as String
                && ["打开", "Open"].contains(match.title ?? "")
                && match.enabled == true
                && match.hidden != true
        }
        guard buttonMatches.count == 1,
              let button = buttonMatches.first,
              let buttonTitle = button.title
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E Open panel did not expose one enabled localized Open button"
            )
        }
        let buttonFrame = try target.requiredFrame(
            button,
            description: "E2E Open panel exact Open button"
        )
        try ledger?.pass(
            "open-button",
            "title=\(buttonTitle) role=AXButton enabled=true hidden=false "
                + "unique=exact frame=\(buttonFrame)"
        )

        let currentReady = try OpenPanelPhysicalInputProtocolFile.readReady(
            from: URL(fileURLWithPath: configuration.openPanelReadyPath)
        )
        let currentCGWindow = try exactOpenPanelCGWindow()
        let currentMatches = target.windows().filter { window in
            target.string(window, kAXRoleAttribute as String)
                == kAXWindowRole as String
                && target.string(window, kAXTitleAttribute as String)
                == configuration.windowTitle
                && target.windowNumber(window) == configuration.windowNumber
                && target.frame(window) == currentCGWindow.frame
        }
        let currentButtonMatches = try target.strictDescendants(of: panel).filter {
            match in
            match.role == kAXButtonRole as String
                && match.title == buttonTitle
                && match.enabled == true
                && match.hidden != true
        }
        guard currentReady == expectedReady,
              currentMatches.count == 1,
              let currentPanel = currentMatches.first,
              CFEqual(currentPanel, panel),
              currentCGWindow.frame == cgWindow.frame,
              let currentFocusedWindow = target.element(
                  target.application,
                  kAXFocusedWindowAttribute as String
              ),
              CFEqual(currentFocusedWindow, panel),
              currentButtonMatches.count == 1,
              let currentButton = currentButtonMatches.first,
              CFEqual(currentButton.element, button.element),
              target.requiredFrameOrNil(currentButton.element) == buttonFrame
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E Open panel identity or exact Open button changed before mouseDown"
            )
        }

        try input.click(frame: buttonFrame)
        let _: Bool = try target.wait(
            description: "the exact E2E Open panel to close after its physical click"
        ) {
            let focused = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            )
            guard focused.map({ CFEqual($0, panel) }) != true else { return nil }
            if let snapshot = ScopedWindowServerLookup.snapshot(
                windowNumber: configuration.windowNumber
            ), snapshot.isOnscreen {
                return nil
            }
            return true
        }
        guard input.leftButtonIsDown == false else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "E2E Open panel physical click left the global button down"
            )
        }
        try ledger?.pass(
            "open-action",
            "source=cghidEventTap clicks=1 panel_closed=true "
                + "left_button_up=true selected_path=\(expectedReady.selectedPath)"
        )
        return buttonTitle
    }

    func performDiagnosticExport() throws {
        guard let diagnosticScope else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic export runner has no pinned scope"
            )
        }
        let correlated = try correlatedE2EWindow(requireFocused: true)
        let exportURL = URL(fileURLWithPath: configuration.exportPath)
        try requireDiagnosticExportDestination(scope: diagnosticScope)
        try ledger?.pass(
            "diagnostic-window",
            "window_number=\(configuration.windowNumber) "
                + "frame=\(correlated.frame) focused=true exact=true"
        )

        let menuSelection = try selectPhysicalMenuCommand(
            topLevelTitles: ["帮助", "Help"],
            itemTitles: ["导出诊断资料…", "Export Diagnostics…"],
            shortcut: .none,
            description: "Export Diagnostics menu command"
        )
        try ledger?.pass(
            "diagnostic-menu",
            "title=\(menuSelection.itemTitle) shortcut=none "
                + "source=cghidEventTap pre_mouse_down=exact "
                + "menu_closed=true left_button_up=true"
        )

        let preview: AXUIElement
        do {
            preview = try target.wait(
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
        } catch {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic export preview was not exact; observed="
                    + diagnosticPreviewStateSummary()
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
        let focusedSavePanel: AXUIElement = try target.wait(
            description: "focused app-owned diagnostic save panel"
        ) {
            guard let focusedWindow = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            ), CFEqual(focusedWindow, savePanel) else { return nil }
            return focusedWindow
        }
        guard CFEqual(focusedSavePanel, savePanel) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic save panel lost its exact focused identity"
            )
        }
        try input.keyStroke(
            virtualKey: 5,
            flags: [.maskCommand, .maskShift]
        )
        let goToContext: (sheet: AXUIElement, locationField: AXUIElement)
        do {
            goToContext = try target.wait(
                description: "exact focused save-panel GoToWindow context"
            ) {
                guard let focusedWindow = target.element(
                    target.application,
                    kAXFocusedWindowAttribute as String
                ),
                    let focused = target.element(
                        target.application,
                        kAXFocusedUIElementAttribute as String
                    ),
                    target.string(focused, kAXRoleAttribute as String)
                    == kAXTextFieldRole as String,
                    let sheet = target.element(
                        focused,
                        kAXParentAttribute as String
                    ),
                    CFEqual(focusedWindow, sheet),
                    let sheetParent = target.element(
                        sheet,
                        kAXParentAttribute as String
                    ), CFEqual(sheetParent, savePanel),
                    let identifier = target.string(
                        sheet,
                        kAXIdentifierAttribute as String
                    ), identifier == "GoToWindow",
                    target.string(sheet, kAXRoleAttribute as String)
                    == kAXSheetRole as String
                else { return nil }
                return (sheet: sheet, locationField: focused)
            }
        } catch {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic GoToWindow AX context mismatch; observed="
                    + diagnosticGoToContextSummary(savePanel: savePanel)
            )
        }
        let locationField = goToContext.locationField
        let goToSheet = goToContext.sheet
        let exportParent = exportURL.deletingLastPathComponent().path
        try replaceFocusedTextField(
            locationField,
            with: exportParent,
            description: "save-panel location"
        )
        let _: AXTarget.Match = try target.wait(
            description: "selected save-panel location suggestion"
        ) {
            let rows = try target.strictMatches(
                in: goToSheet,
                roles: [kAXRowRole as String]
            )
            let selectedRows = rows.filter {
                target.boolean(
                    $0.element,
                    kAXSelectedAttribute as String
                ) == true
            }
            guard selectedRows.count <= 1 else {
                throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                    "GoToWindow exposed duplicate selected suggestions"
                )
            }
            return selectedRows.first
        }
        try input.keyStroke(virtualKey: 36)

        let saveButton = try uniqueMatch(
            in: savePanel,
            roles: [kAXButtonRole as String],
            titles: ["存储", "保存", "Save"],
            identifier: nil,
            description: "diagnostic save button"
        )
        let _: Bool = try target.wait(
            description: "dismissed save-panel location sheet"
        ) {
            guard let focusedWindow = target.element(
                target.application,
                kAXFocusedWindowAttribute as String
            ), CFEqual(focusedWindow, savePanel),
                let focused = target.element(
                    target.application,
                    kAXFocusedUIElementAttribute as String
                ), CFEqual(focused, locationField) == false,
                target.boolean(
                    saveButton.element,
                    kAXEnabledAttribute as String
                ) == true
            else { return nil }
            return true
        }

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
        try replaceFocusedTextField(
            nameField.element,
            with: basename,
            description: "diagnostic filename"
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
            guard try diagnosticScope.artifactDirectory.openExistingFileIfPresent(
                named: diagnosticScope.exportFileName,
                writable: false
            ) != nil else {
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

    private func replaceFocusedTextField(
        _ field: AXUIElement,
        with expectedValue: String,
        description: String
    ) throws {
        guard expectedValue.isEmpty == false,
              target.string(field, kAXRoleAttribute as String)
              == kAXTextFieldRole as String
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "\(description) replacement requires a nonempty exact text field"
            )
        }
        try input.click(
            frame: target.requiredFrame(
                field,
                description: "\(description) field"
            ),
            clickCount: 3
        )
        let _: Bool = try target.wait(description: "focused \(description) field") {
            guard let focused = target.element(
                target.application,
                kAXFocusedUIElementAttribute as String
            ), CFEqual(focused, field) else { return nil }
            return true
        }
        try input.keyStroke(virtualKey: 51)
        let _: Bool = try target.wait(description: "cleared \(description) value") {
            guard let focused = target.element(
                target.application,
                kAXFocusedUIElementAttribute as String
            ), CFEqual(focused, field),
                let currentValue = target.string(
                    field,
                    kAXValueAttribute as String
                ), currentValue.isEmpty
            else { return nil }
            return true
        }
        try input.typeUnicode(expectedValue)
        let _: Bool = try target.wait(description: "exact \(description) value") {
            guard let focused = target.element(
                target.application,
                kAXFocusedUIElementAttribute as String
            ), CFEqual(focused, field),
                target.string(field, kAXValueAttribute as String)
                == expectedValue
            else { return nil }
            return true
        }
    }

    private func requireDiagnosticExportDestination(
        scope: PinnedDiagnosticExportScope
    ) throws {
        guard try scope.artifactDirectory.openExistingFileIfPresent(
            named: scope.exportFileName,
            writable: false
        ) == nil else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "diagnostic export destination already exists"
            )
        }
        try scope.artifactDirectory.validatePathBinding()
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

    private func diagnosticPreviewStateSummary() -> String {
        let previewTitles: Set<String> = [
            "导出前预览", "Preview Before Export"
        ]
        let continueTitles: Set<String> = [
            "选择保存位置…", "Choose Save Location…"
        ]
        let cancelTitles: Set<String> = ["取消", "Cancel"]
        let savePanelTitles: Set<String> = [
            "导出晷迹诊断资料", "Export Noonmark Diagnostics"
        ]
        let windows = target.windows()
        let focusedWindow = target.element(
            target.application,
            kAXFocusedWindowAttribute as String
        )
        let windowSummaries = windows.prefix(8).enumerated().map { index, window in
            let descendants = target.descendants(
                of: window,
                maximumDepth: 8,
                maximumCount: 256
            )
            let textValues = descendants.compactMap { match in
                match.title
                    ?? target.string(match.element, kAXValueAttribute as String)
                    ?? match.description
            }
            let windowTitle = target.string(
                window,
                kAXTitleAttribute as String
            )
            let titleClass: String
            if windowTitle == configuration.windowTitle {
                titleClass = "main"
            } else if windowTitle.map(previewTitles.contains) == true {
                titleClass = "preview"
            } else if windowTitle.map(savePanelTitles.contains) == true {
                titleClass = "save-panel"
            } else {
                titleClass = "other"
            }
            let previewTitleCount = textValues.count {
                previewTitles.contains($0)
            }
            let continueCount = descendants.count { match in
                match.role == kAXButtonRole as String
                    && continueTitles.contains(match.title ?? "")
            }
            let cancelCount = descendants.count { match in
                match.role == kAXButtonRole as String
                    && cancelTitles.contains(match.title ?? "")
            }
            let focused = focusedWindow.map { CFEqual($0, window) } == true
            let role = target.string(
                window,
                kAXRoleAttribute as String
            ) ?? "nil"
            let windowNumber = target.windowNumber(window).map(String.init) ?? "nil"
            return "index=\(index),role=\(role),title_class=\(titleClass),"
                + "window_number=\(windowNumber),focused=\(focused),"
                + "preview_titles=\(previewTitleCount),"
                + "continue_buttons=\(continueCount),cancel_buttons=\(cancelCount)"
        }
        let exportMenuState: String
        if let menuBar = try? target.menuBar() {
            let matches = target.matches(
                in: menuBar,
                roles: [kAXMenuItemRole as String],
                titles: ["导出诊断资料…", "Export Diagnostics…"]
            )
            exportMenuState = "matches=\(matches.count),visible=\(matches.count { $0.hidden != true }),"
                + "enabled=\(matches.count { $0.enabled == true })"
        } else {
            exportMenuState = "unavailable"
        }
        return "window_count=\(windows.count) export_menu={\(exportMenuState)} "
            + "windows=[\(windowSummaries.joined(separator: ";"))]"
    }

    private func diagnosticGoToContextSummary(savePanel: AXUIElement) -> String {
        let windows = target.windows()
        let focusedWindow = target.element(
            target.application,
            kAXFocusedWindowAttribute as String
        )
        let focusedUI = target.element(
            target.application,
            kAXFocusedUIElementAttribute as String
        )
        var focusChain: [String] = []
        var current = focusedUI
        for depth in 0 ..< 6 {
            guard let element = current else { break }
            focusChain.append(
                "depth=\(depth){\(diagnosticElementIdentity(element, savePanel: savePanel, windows: windows))}"
            )
            current = target.element(element, kAXParentAttribute as String)
        }

        var goToCandidates: [AXUIElement] = []
        for window in windows {
            let elements = [window] + target.descendants(
                of: window,
                maximumDepth: 12,
                maximumCount: 512
            ).map(\.element)
            goToCandidates += elements.filter {
                target.string($0, kAXIdentifierAttribute as String) == "GoToWindow"
            }
        }
        let candidateSummary = goToCandidates.enumerated().map { index, candidate in
            "candidate=\(index){\(diagnosticElementIdentity(candidate, savePanel: savePanel, windows: windows))}"
        }.joined(separator: ",")
        let focusedWindowSummary = focusedWindow.map {
            diagnosticElementIdentity($0, savePanel: savePanel, windows: windows)
        } ?? "nil"
        return "focused_window={\(focusedWindowSummary)} "
            + "focus_chain=[\(focusChain.joined(separator: ","))] "
            + "goto_count=\(goToCandidates.count) goto=[\(candidateSummary)]"
    }

    private func diagnosticElementIdentity(
        _ element: AXUIElement,
        savePanel: AXUIElement,
        windows: [AXUIElement]
    ) -> String {
        let windowIndex = windows.firstIndex { CFEqual($0, element) }
            .map(String.init) ?? "none"
        return "role=\(target.string(element, kAXRoleAttribute as String) ?? "nil") "
            + "subrole=\(target.string(element, kAXSubroleAttribute as String) ?? "nil") "
            + "identifier=\(target.string(element, kAXIdentifierAttribute as String) ?? "nil") "
            + "focused=\(target.boolean(element, kAXFocusedAttribute as String).map(String.init) ?? "nil") "
            + "is_save_panel=\(CFEqual(element, savePanel)) window_index=\(windowIndex)"
    }

    private func selectPhysicalMenuCommand(
        topLevelTitles: Set<String>,
        itemTitles: Set<String>,
        shortcut: PhysicalMenuShortcut,
        description: String
    ) throws -> PhysicalMenuSelection {
        try target.waitUntilFrontmost()
        let menuBar = try target.menuBar()
        let topLevelMatches = target.directMatches(
            in: menuBar,
            roles: [kAXMenuBarItemRole as String],
            titles: topLevelTitles,
            identifier: nil
        )
        guard topLevelMatches.count == 1 else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "top-level physical menu count was \(topLevelMatches.count), expected 1"
            )
        }
        let topLevel = topLevelMatches[0]
        guard topLevel.enabled == true, topLevel.hidden != true,
              let topLevelTitle = topLevel.title
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "top-level physical menu was not visible, enabled, and titled"
            )
        }
        let topLevelFrame = try target.requiredFrame(
            topLevel,
            description: "top-level physical menu"
        )
        try input.click(
            frame: topLevelFrame
        )
        let initialItem: AXTarget.Match = try target.wait(
            description: "the exact visible \(description)"
        ) {
            try strictVisibleMenuItem(
                in: menuBar,
                titles: itemTitles,
                description: description
            )
        }
        try validatePhysicalMenuShortcut(shortcut, item: initialItem)
        let initialItemFrame = try target.requiredFrame(
            initialItem,
            description: description
        )

        let currentTopLevelMatches = target.directMatches(
            in: menuBar,
            roles: [kAXMenuBarItemRole as String],
            titles: topLevelTitles,
            identifier: nil
        )
        guard target.boolean(
            target.application,
            kAXFrontmostAttribute as String
        ) == true,
            currentTopLevelMatches.count == 1
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "physical menu command lost its frontmost top-level menu before mouseDown"
            )
        }
        let currentTopLevel = currentTopLevelMatches[0]
        guard
            CFEqual(currentTopLevel.element, topLevel.element),
            currentTopLevel.enabled == true,
            currentTopLevel.hidden != true,
            target.requiredFrameOrNil(currentTopLevel.element) == topLevelFrame,
            let currentItem = try strictVisibleMenuItem(
                in: menuBar,
                titles: itemTitles,
                description: description
            ),
            CFEqual(currentItem.element, initialItem.element),
            let currentItemFrame = target.requiredFrameOrNil(currentItem.element),
            currentItemFrame == initialItemFrame,
            currentItem.title == initialItem.title
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "physical menu command identity or frame changed before mouseDown"
            )
        }
        try validatePhysicalMenuShortcut(shortcut, item: currentItem)
        guard input.leftButtonIsDown == false else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "physical menu command began while the global button was down"
            )
        }
        try input.click(frame: currentItemFrame)
        let _: Bool = try target.wait(
            description: "the physical menu command to close its menu"
        ) {
            if kill(configuration.pid, 0) == -1, errno == ESRCH {
                return true
            }
            return try strictVisibleMenuItem(
                in: menuBar,
                titles: itemTitles,
                description: description
            ) == nil ? true : nil
        }
        guard input.leftButtonIsDown == false else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "physical menu command left the global button down"
            )
        }
        return PhysicalMenuSelection(
            topLevelTitle: topLevelTitle,
            topLevelFrame: topLevelFrame,
            itemTitle: currentItem.title ?? "unknown",
            itemFrame: currentItemFrame,
            itemHidden: currentItem.hidden
        )
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

    private func strictVisibleMenuItem(
        in menuBar: AXUIElement,
        titles: Set<String>,
        description: String
    ) throws -> AXTarget.Match? {
        let exactMatches = try target.strictMatches(
            in: menuBar,
            roles: [kAXMenuItemRole as String],
            titles: titles
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
                "exact visible \(description) was duplicated: count=\(matches.count) "
                    + "observed=\(observed)"
            )
        }
        guard let match = matches.first else {
            return nil
        }
        guard match.enabled == true else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "exact visible \(description) was disabled"
            )
        }
        return match
    }

    private func validatePhysicalMenuShortcut(
        _ shortcut: PhysicalMenuShortcut,
        item: AXTarget.Match
    ) throws {
        let key = target.string(
            item.element,
            kAXMenuItemCmdCharAttribute as String
        )
        let modifiers = target.integer(
            item.element,
            kAXMenuItemCmdModifiersAttribute as String
        )
        let valid = switch shortcut {
        case .none:
            key == nil
        case let .command(expectedKey):
            key?.lowercased() == expectedKey.lowercased() && modifiers == 0
        }
        guard valid else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "physical menu shortcut mismatch: key=\(key ?? "nil") "
                    + "modifiers=\(modifiers.map(String.init) ?? "nil")"
            )
        }
    }

    private func onscreenCGWindow(
        windowNumber: CGWindowID,
        frame: CGRect,
        title: String
    ) throws -> (number: CGWindowID, title: String?)? {
        guard let snapshot = ScopedWindowServerLookup.snapshot(
            windowNumber: windowNumber
        ),
            snapshot.ownerProcessID == configuration.pid,
            snapshot.title == nil || snapshot.title == title,
            snapshot.layer == 0,
            snapshot.isOnscreen,
            let alpha = snapshot.alpha,
            alpha > 0,
            snapshot.frame == frame
        else {
            return nil
        }
        return (number: snapshot.windowNumber, title: snapshot.title)
    }

    private func exactCGWindow() throws -> (frame: CGRect, title: String?) {
        guard let snapshot = ScopedWindowServerLookup.snapshot(
            windowNumber: configuration.windowNumber
        ) else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CGWindowNumber \(configuration.windowNumber) did not resolve exactly once"
            )
        }
        guard let frame = snapshot.frame else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CGWindowNumber \(configuration.windowNumber) has no complete bounds"
            )
        }
        guard snapshot.ownerProcessID == configuration.pid,
              snapshot.windowNumber == configuration.windowNumber,
              snapshot.title == nil || snapshot.title == configuration.windowTitle,
              snapshot.layer == 0,
              snapshot.isOnscreen,
              let alpha = snapshot.alpha,
              alpha > 0,
              frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "CG window identity mismatch "
                    + "pid=\(snapshot.ownerProcessID.map { String($0) } ?? "nil") "
                    + "number=\(snapshot.windowNumber) "
                    + "title=\(snapshot.title ?? "nil") "
                    + "layer=\(snapshot.layer.map { String($0) } ?? "nil") "
                    + "onscreen=\(snapshot.isOnscreen) "
                    + "alpha=\(snapshot.alpha.map { String($0) } ?? "nil") "
                    + "frame=\(frame)"
            )
        }
        return (frame: frame, title: snapshot.title)
    }

    private func exactOpenPanelCGWindow() throws -> (
        frame: CGRect,
        title: String?,
        ownerPID: pid_t
    ) {
        guard let ready = configuration.openPanelReady,
              let snapshot = ScopedWindowServerLookup.snapshot(
                  windowNumber: configuration.windowNumber
              ),
            let frame = snapshot.frame,
            let ownerPID = snapshot.ownerProcessID,
            ownerPID > 0,
            ownerPID == configuration.pid,
            snapshot.windowNumber == configuration.windowNumber,
            snapshot.title == nil || snapshot.title == configuration.windowTitle,
            snapshot.layer == ready.panelLayer,
            snapshot.isOnscreen,
            let alpha = snapshot.alpha,
            alpha > 0,
            frame.isNull == false,
            frame.isInfinite == false,
            frame.width >= 2,
            frame.height >= 2
        else {
            throw NoonmarkDMGInstallHarness.HarnessFailure.contract(
                "exact remote Open panel WindowServer identity was unavailable"
            )
        }
        return (frame: frame, title: snapshot.title, ownerPID: ownerPID)
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
        let settingsSelection = try selectPhysicalMenuCommand(
            topLevelTitles: ["晷迹", "Noonmark"],
            itemTitles: ["设置…", "Settings…"],
            shortcut: .command(","),
            description: "Settings menu command"
        )
        try ledger?.pass(
            "settings-menu",
            "title=\(settingsSelection.itemTitle) shortcut=Command-, "
                + "source=cghidEventTap pre_mouse_down=exact "
                + "menu_closed=true left_button_up=true"
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
        let quickEntrySelection = try selectPhysicalMenuCommand(
            topLevelTitles: ["文件", "File"],
            itemTitles: ["快速记录…", "Quick Entry…"],
            shortcut: .command("n"),
            description: "Quick Entry menu command"
        )
        try ledger?.pass(
            "quick-entry-menu",
            "title=\(quickEntrySelection.itemTitle) shortcut=Command-n "
                + "source=cghidEventTap pre_mouse_down=exact "
                + "menu_closed=true left_button_up=true"
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
        let quitSelection = try selectPhysicalMenuCommand(
            topLevelTitles: ["晷迹", "Noonmark"],
            itemTitles: ["退出晷迹", "Quit Noonmark"],
            shortcut: .command("q"),
            description: "Quit menu command"
        )
        try ledger?.pass(
            "quit-menu",
            "title=\(quitSelection.itemTitle) shortcut=Command-q "
                + "source=cghidEventTap pre_mouse_down=exact "
                + "menu_closed=true left_button_up=true"
        )
        let pid = configuration.pid
        _ = try target.wait(seconds: 12, description: "validation app to terminate") {
            kill(pid, 0) == -1 && errno == ESRCH ? true : nil
        }
        try ledger?.pass("quit", "terminated via real App menu click")
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
