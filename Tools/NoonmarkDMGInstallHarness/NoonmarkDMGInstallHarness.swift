import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
enum NoonmarkDMGInstallHarness {
    private static let expectedProductionBundleIdentifier = "app.noonmark.mac"

    enum Mode: String {
        case preflight
        case exercise
        case restart
    }

    struct Configuration {
        let mode: Mode
        let pid: pid_t
        let appPath: String
        let taskTitle: String
        let ledgerPath: String

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
            let allowed = Set(["--mode", "--pid", "--app-path", "--task-title", "--ledger"])
            let unknown = Set(values.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                throw HarnessFailure.invalidArguments(
                    "unknown options: \(unknown.sorted().joined(separator: ", "))"
                )
            }
            guard let rawMode = values["--mode"], let mode = Mode(rawValue: rawMode),
                  let ledgerPath = values["--ledger"], ledgerPath.isEmpty == false
            else {
                throw HarnessFailure.invalidArguments(
                    "required: --mode preflight|exercise|restart --ledger PATH"
                )
            }
            if mode == .preflight {
                guard values.count == 2 else {
                    throw HarnessFailure.invalidArguments(
                        "preflight accepts only --mode preflight --ledger PATH"
                    )
                }
                return Self(
                    mode: mode,
                    pid: 0,
                    appPath: "",
                    taskTitle: "",
                    ledgerPath: ledgerPath
                )
            }
            guard
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
                ledgerPath: ledgerPath
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
                "Production target identity failed: \(reason)"
            case let .contract(reason):
                "Production UI contract failed: \(reason)"
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

            let input = try WindowServerInputDriver()
            try ledger?.pass(
                "permissions",
                "AXIsProcessTrusted=true CGPreflightPostEventAccess=true"
            )
            if configuration.mode == .preflight {
                try ledger?.pass("complete", "mode=preflight")
                exit(EXIT_SUCCESS)
            }

            let target = try validateProductionTarget(
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
                throw HarnessFailure.contract("preflight reached the production runner")
            case .exercise:
                try runner.exercise()
            case .restart:
                try runner.verifyRestart()
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

    private static func validateProductionTarget(
        configuration: Configuration,
        ledger: HarnessLedger?
    ) throws -> AXTarget {
        guard let running = NSRunningApplication(
            processIdentifier: configuration.pid
        ), running.isTerminated == false else {
            throw HarnessFailure.targetIdentity(
                "pid \(configuration.pid) is not a running application"
            )
        }
        guard running.bundleIdentifier == expectedProductionBundleIdentifier else {
            throw HarnessFailure.targetIdentity(
                "bundle id was \(running.bundleIdentifier ?? "nil"), expected "
                    + expectedProductionBundleIdentifier
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
            throw HarnessFailure.targetIdentity("production app is not frontmost")
        }
        guard target.windows().isEmpty == false else {
            throw HarnessFailure.targetIdentity("production app exposes no AX windows")
        }
        try ledger?.pass(
            "target",
            "bundle=\(expectedProductionBundleIdentifier) path=\(actualURL.path) "
                + "frontmost=true windows=\(target.windows().count)"
        )
        return target
    }
}

private extension NoonmarkDMGInstallHarness.Configuration {
    var argumentDetail: String {
        if mode == .preflight { return "mode=preflight" }
        return "mode=\(mode.rawValue) pid=\(pid) app=\(appPath)"
    }
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
                "no production main window with a usable native window role"
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
                "Settings reused a preexisting production window"
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
            description: "persisted task title in the production AX tree"
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
        _ = try target.wait(seconds: 12, description: "production app to terminate") {
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
