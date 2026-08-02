import Darwin
import Foundation
@testable import NoonmarkDMGInstallHarness
import XCTest

final class DiagnosticExportScopeContractTests: XCTestCase {
    func testDiagnosticExportAcceptsOnlyTheExactE2EScope() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }

        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.arguments()
        )
        XCTAssertNoThrow(
            try DiagnosticExportScopeContract.pin(configuration)
        )
    }

    func testDiagnosticExportRejectsProductionDatabaseForE2ETarget() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }

        let productionDatabase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("noonmark", isDirectory: true)
        .appendingPathComponent("Noonmark.sqlite", isDirectory: false)

        XCTAssertThrowsError(
            try NoonmarkDMGInstallHarness.Configuration.parse(
                fixture.arguments(databasePath: productionDatabase.path)
            )
        )
    }

    func testDiagnosticExportRejectsEveryNonExactE2EResourcePath() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }

        let outside = fixture.root.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        let overrides = [
            "--database": outside.appendingPathComponent("Noonmark.sqlite").path,
            "--repository-lock": outside
                .appendingPathComponent(".repository.lock")
                .path,
            "--export-path": outside
                .appendingPathComponent("export.noonmarkdiagnostics")
                .path,
            "--sentinels": outside
                .appendingPathComponent("privacy-sentinels.txt")
                .path,
            "--ledger": outside.appendingPathComponent("ledger.tsv").path,
            "--start-gate": outside
                .appendingPathComponent("exit-observer-gate.txt")
                .path
        ]

        for (option, path) in overrides {
            XCTAssertThrowsError(
                try NoonmarkDMGInstallHarness.Configuration.parse(
                    fixture.arguments(overrides: [option: path])
                ),
                "expected exact-scope rejection for \(option)"
            )
        }
    }

    func testDiagnosticExportRejectsAnExactLookingE2EPathThroughASymlink() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }

        let realApp = fixture.root.appendingPathComponent(
            "RealNoonmarkE2E.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realApp,
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: fixture.appURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.appURL,
            withDestinationURL: realApp
        )

        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.arguments()
        )
        XCTAssertThrowsError(
            try DiagnosticExportScopeContract.pin(configuration)
        )
    }

    func testDiagnosticExportRejectsAHardLinkAtTheExactE2EDatabasePath() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }
        let protectedFile = fixture.root.appendingPathComponent("protected.sqlite")
        try Data("not-a-real-database".utf8).write(to: protectedFile)
        let exactDatabase = fixture.evidenceRoot.appendingPathComponent(
            "Noonmark.sqlite"
        )
        let linkResult = protectedFile.path.withCString { source in
            exactDatabase.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linkResult, 0)

        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.arguments()
        )
        let scope = try DiagnosticExportScopeContract.pin(configuration)
        XCTAssertThrowsError(
            try scope.databaseDirectory.openExistingFile(
                named: scope.databaseFileName,
                writable: false
            )
        )
    }

    func testDiagnosticExportAcceptsOnlyTheExactDMGValidationScope() throws {
        let fixture = try DMGScopeFixture()
        defer { fixture.remove() }

        XCTAssertNoThrow(
            try DiagnosticExportScopeContract.validate(
                fixture.configuration(),
                applicationSupportBaseURL: fixture.applicationSupportBaseURL
            )
        )
        XCTAssertNoThrow(
            try DiagnosticExportScopeContract.pin(
                fixture.configuration(),
                applicationSupportBaseURL: fixture.applicationSupportBaseURL
            )
        )
        XCTAssertThrowsError(
            try DiagnosticExportScopeContract.validate(
                fixture.configuration(
                    exportPath: fixture.workRoot
                        .appendingPathComponent("wrong.noonmarkdiagnostics")
                        .path
                ),
                applicationSupportBaseURL: fixture.applicationSupportBaseURL
            )
        )
    }

    func testDiagnosticExportScopeModeEmitsTheCanonicalVersionedLayout() throws {
        let fixture = try DMGScopeFixture()
        defer { fixture.remove() }

        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.scopeArguments()
        )
        let manifest = try DiagnosticExportScopeContract.scopeManifest(
            configuration,
            applicationSupportBaseURL: fixture.applicationSupportBaseURL,
            homeDirectoryURL: fixture.root
        )

        XCTAssertEqual(configuration.mode, .diagnosticExportScope)
        XCTAssertEqual(
            manifest,
            [
                "schema_version\t1",
                "target_profile\tdmg-validation",
                "application\t\(fixture.appURL.path)",
                "database\t\(fixture.databaseURL.path)",
                "repository_lock\t\(fixture.repositoryLockURL.path)",
                "export\t\(fixture.exportURL.path)",
                "sentinels\t\(fixture.sentinelsURL.path)",
                "ledger\t\(fixture.workRoot.path)/helper/ledger.tsv",
                "start_gate\t\(fixture.workRoot.path)/helper/exit-observer-gate.txt",
                ""
            ].joined(separator: "\n")
        )
    }

    func testDiagnosticExportScopeModeRejectsCallerSuppliedResources() throws {
        let fixture = try DMGScopeFixture()
        defer { fixture.remove() }
        let unexpectedArguments = fixture.scopeArguments() + [
            "--ledger", fixture.workRoot
                .appendingPathComponent("caller-ledger.tsv")
                .path
        ]

        XCTAssertThrowsError(
            try NoonmarkDMGInstallHarness.Configuration.parse(
                unexpectedArguments
            )
        )
    }

    func testDiagnosticExportRejectsAnE2EScopeNestedInProductionData() throws {
        let temporaryRoot = fixtureBaseURL
            .appendingPathComponent(
                "noonmark-production-overlap-\(UUID().uuidString)",
                isDirectory: true
            )
        let applicationSupport = temporaryRoot
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let repositoryRoot = applicationSupport
            .appendingPathComponent("noonmark", isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
        let fixture = try ScopeFixture(root: repositoryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.arguments()
        )

        XCTAssertThrowsError(
            try DiagnosticExportScopeContract.validate(
                configuration,
                applicationSupportBaseURL: applicationSupport
            )
        )
    }

    func testDiagnosticExportRejectsAnE2EScopeNestedInProductionICloud() throws {
        let temporaryRoot = fixtureBaseURL.appendingPathComponent(
            "noonmark-production-icloud-overlap-\(UUID().uuidString)",
            isDirectory: true
        )
        let homeDirectory = temporaryRoot.appendingPathComponent(
            "home",
            isDirectory: true
        )
        let productionRepository = homeDirectory
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true
            )
            .appendingPathComponent("Noonmark/SyncRepository", isDirectory: true)
        let fixture = try ScopeFixture(
            root: productionRepository.appendingPathComponent(
                "source",
                isDirectory: true
            )
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            fixture.arguments()
        )

        XCTAssertThrowsError(
            try DiagnosticExportScopeContract.validate(
                configuration,
                applicationSupportBaseURL: temporaryRoot.appendingPathComponent(
                    "Application Support",
                    isDirectory: true
                ),
                homeDirectoryURL: homeDirectory
            )
        )
    }

    func testDiagnosticExportRejectsLexicalAliasesWithoutFilesystemResolution() throws {
        let fixture = try ScopeFixture()
        defer { fixture.remove() }
        let existingAlias = fixture.evidenceRoot.path
            + "/../e2e-diagnostic-closure/Noonmark.sqlite"
        let nonexistingAlias = fixture.root.path
            + "/missing/../artifacts/e2e-diagnostic-closure/Noonmark.sqlite"
        let noncanonicalPaths = [
            existingAlias,
            nonexistingAlias,
            fixture.evidenceRoot.path + "//Noonmark.sqlite",
            fixture.evidenceRoot.path + "/Noonmark.sqlite/",
            "/"
        ]

        for path in noncanonicalPaths {
            XCTAssertThrowsError(
                try NoonmarkDMGInstallHarness.Configuration.parse(
                    fixture.arguments(databasePath: path)
                ),
                "expected pure lexical rejection for \(path)"
            )
        }
    }

    func testDiagnosticExportArgumentValidationDoesNotProbeMissingScope() throws {
        let fixture = try ScopeFixture()
        let arguments = fixture.arguments()
        fixture.remove()

        XCTAssertNoThrow(
            try NoonmarkDMGInstallHarness.Configuration.parse(arguments)
        )
    }
}

private struct ScopeFixture {
    let root: URL
    let appURL: URL
    let evidenceRoot: URL

    init(root explicitRoot: URL? = nil) throws {
        root = explicitRoot ?? fixtureBaseURL
            .appendingPathComponent(
                "noonmark-diagnostic-scope-\(UUID().uuidString)",
                isDirectory: true
            )
        appURL = root
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("NoonmarkE2E.app", isDirectory: true)
        evidenceRoot = root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(
                "e2e-diagnostic-closure",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: evidenceRoot.appendingPathComponent(
                "SyncRepository",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: evidenceRoot.appendingPathComponent("helper", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func arguments(
        databasePath: String? = nil,
        overrides: [String: String] = [:]
    ) -> [String] {
        let database = databasePath ?? evidenceRoot
            .appendingPathComponent("Noonmark.sqlite")
            .path
        var arguments = [
            "--mode", "diagnostic-export",
            "--ledger", evidenceRoot
                .appendingPathComponent("helper", isDirectory: true)
                .appendingPathComponent("ledger.tsv")
                .path,
            "--launch-token", "11111111-1111-4111-8111-111111111111",
            "--start-gate", evidenceRoot
                .appendingPathComponent("helper", isDirectory: true)
                .appendingPathComponent("exit-observer-gate.txt")
                .path,
            "--pid", "123",
            "--app-path", appURL.path,
            "--window-number", "456",
            "--window-title", "晷迹 · Day Todo — 7月5日",
            "--target-profile", "e2e",
            "--database", database,
            "--repository-lock", evidenceRoot
                .appendingPathComponent("SyncRepository", isDirectory: true)
                .appendingPathComponent(".repository.lock")
                .path,
            "--export-path", evidenceRoot
                .appendingPathComponent(
                    "Noonmark-Diagnostic-Closure.noonmarkdiagnostics"
                )
                .path,
            "--sentinels", evidenceRoot
                .appendingPathComponent("privacy-sentinels.txt")
                .path
        ]
        for (option, value) in overrides {
            guard let optionIndex = arguments.firstIndex(of: option) else {
                preconditionFailure("unknown fixture option \(option)")
            }
            arguments[optionIndex + 1] = value
        }
        return arguments
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct DMGScopeFixture {
    let root: URL
    let workRoot: URL
    let appURL: URL
    let applicationSupportBaseURL: URL
    let databaseURL: URL
    let repositoryLockURL: URL
    let exportURL: URL
    let sentinelsURL: URL

    init() throws {
        root = fixtureBaseURL
            .appendingPathComponent(
                "noonmark-dmg-diagnostic-scope-\(UUID().uuidString)",
                isDirectory: true
            )
        workRoot = root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("dmg-install", isDirectory: true)
        appURL = workRoot
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("NoonmarkDMGValidation.app", isDirectory: true)
        applicationSupportBaseURL = root
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dataRoot = applicationSupportBaseURL
            .appendingPathComponent("noonmark-dmg-validation", isDirectory: true)
        databaseURL = dataRoot.appendingPathComponent("Noonmark.sqlite")
        repositoryLockURL = dataRoot
            .appendingPathComponent("sync-repository", isDirectory: true)
            .appendingPathComponent(".repository.lock")
        exportURL = workRoot.appendingPathComponent(
            "Noonmark-DMGValidation-Diagnostics.noonmarkdiagnostics"
        )
        sentinelsURL = workRoot.appendingPathComponent(
            "diagnostic-export-sentinels.txt"
        )
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repositoryLockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workRoot.appendingPathComponent("helper", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func configuration(exportPath: String? = nil) -> NoonmarkDMGInstallHarness.Configuration {
        NoonmarkDMGInstallHarness.Configuration(
            mode: .diagnosticExport,
            pid: 123,
            appPath: appURL.path,
            taskTitle: "",
            ledgerPath: workRoot
                .appendingPathComponent("helper", isDirectory: true)
                .appendingPathComponent("ledger.tsv")
                .path,
            launchToken: "11111111-1111-4111-8111-111111111111",
            startGatePath: workRoot
                .appendingPathComponent("helper", isDirectory: true)
                .appendingPathComponent("exit-observer-gate.txt")
                .path,
            windowNumber: 456,
            windowTitle: "晷迹 · Day Todo — 7月5日",
            expectationsPath: "",
            menuTitle: "",
            menuItemTitle: "",
            completionPath: "",
            targetProfile: "dmg-validation",
            databasePath: databaseURL.path,
            repositoryLockPath: repositoryLockURL.path,
            exportPath: exportPath ?? exportURL.path,
            sentinelsPath: sentinelsURL.path
        )
    }

    func scopeArguments() -> [String] {
        [
            "--mode", "diagnostic-export-scope",
            "--app-path", appURL.path,
            "--target-profile", "dmg-validation"
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let fixtureBaseURL = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
)
.appendingPathComponent(".build/test-fixtures", isDirectory: true)
