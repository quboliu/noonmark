import Foundation
import NoonmarkMacRuntime

final class PinnedDiagnosticExportScope {
    let application: DescriptorBoundDirectory
    let databaseDirectory: DescriptorBoundDirectory
    let repositoryDirectory: DescriptorBoundDirectory
    let artifactDirectory: DescriptorBoundDirectory
    let controlDirectory: DescriptorBoundDirectory
    let databaseFileName: String
    let repositoryLockFileName: String
    let exportFileName: String
    let sentinelsFileName: String
    let ledgerFileName: String
    let startGateFileName: String

    init(
        application: DescriptorBoundDirectory,
        databaseDirectory: DescriptorBoundDirectory,
        repositoryDirectory: DescriptorBoundDirectory,
        artifactDirectory: DescriptorBoundDirectory,
        controlDirectory: DescriptorBoundDirectory,
        databaseFileName: String,
        repositoryLockFileName: String,
        exportFileName: String,
        sentinelsFileName: String,
        ledgerFileName: String,
        startGateFileName: String
    ) {
        self.application = application
        self.databaseDirectory = databaseDirectory
        self.repositoryDirectory = repositoryDirectory
        self.artifactDirectory = artifactDirectory
        self.controlDirectory = controlDirectory
        self.databaseFileName = databaseFileName
        self.repositoryLockFileName = repositoryLockFileName
        self.exportFileName = exportFileName
        self.sentinelsFileName = sentinelsFileName
        self.ledgerFileName = ledgerFileName
        self.startGateFileName = startGateFileName
    }

    func artifactReader() -> DiagnosticExportFileReader {
        DiagnosticExportFileReader(root: artifactDirectory)
    }

    func controlReader() -> DiagnosticExportFileReader {
        DiagnosticExportFileReader(root: controlDirectory)
    }
}

/// Derives every helper path from an exact nonproduction layout using pure
/// lexical components, then pins each controlled root through no-following
/// directory descriptors before any database or artifact is opened.
enum DiagnosticExportScopeContract {
    static func validate(
        _ configuration: NoonmarkDMGInstallHarness.Configuration
    ) throws {
        guard let applicationSupportBaseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw invalid("the user Application Support root is unavailable")
        }
        _ = try expectedScope(
            configuration,
            applicationSupportBasePath: applicationSupportBaseURL.path,
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static func validate(
        _ configuration: NoonmarkDMGInstallHarness.Configuration,
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        _ = try expectedScope(
            configuration,
            applicationSupportBasePath: applicationSupportBaseURL.path,
            homeDirectoryPath: homeDirectoryURL.path
        )
    }

    static func pin(
        _ configuration: NoonmarkDMGInstallHarness.Configuration
    ) throws -> PinnedDiagnosticExportScope {
        guard let applicationSupportBaseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw invalid("the user Application Support root is unavailable")
        }
        return try pin(
            configuration,
            applicationSupportBaseURL: applicationSupportBaseURL,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func pin(
        _ configuration: NoonmarkDMGInstallHarness.Configuration,
        applicationSupportBaseURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> PinnedDiagnosticExportScope {
        let scope = try expectedScope(
            configuration,
            applicationSupportBasePath: applicationSupportBaseURL.path,
            homeDirectoryPath: homeDirectoryURL.path
        )
        return PinnedDiagnosticExportScope(
            application: try DescriptorBoundDirectory(path: scope.application),
            databaseDirectory: try DescriptorBoundDirectory(
                path: scope.database.parent
            ),
            repositoryDirectory: try DescriptorBoundDirectory(
                path: scope.repositoryLock.parent
            ),
            artifactDirectory: try DescriptorBoundDirectory(
                path: scope.export.parent
            ),
            controlDirectory: try DescriptorBoundDirectory(
                path: scope.ledger.parent
            ),
            databaseFileName: try requiredLeaf(scope.database),
            repositoryLockFileName: try requiredLeaf(scope.repositoryLock),
            exportFileName: try requiredLeaf(scope.export),
            sentinelsFileName: try requiredLeaf(scope.sentinels),
            ledgerFileName: try requiredLeaf(scope.ledger),
            startGateFileName: try requiredLeaf(scope.startGate)
        )
    }

    private struct Scope {
        let application: CanonicalAbsolutePath
        let database: CanonicalAbsolutePath
        let repositoryLock: CanonicalAbsolutePath
        let export: CanonicalAbsolutePath
        let sentinels: CanonicalAbsolutePath
        let ledger: CanonicalAbsolutePath
        let startGate: CanonicalAbsolutePath
    }

    private static func expectedScope(
        _ configuration: NoonmarkDMGInstallHarness.Configuration,
        applicationSupportBasePath: String,
        homeDirectoryPath: String
    ) throws -> Scope {
        guard configuration.mode == .diagnosticExport else {
            throw invalid("only diagnostic-export mode has a pinned scope")
        }
        guard let profile = NoonmarkRuntimeProfile(
            rawValue: configuration.targetProfile
        ), profile == .e2e || profile == .dmgValidation else {
            throw invalid("diagnostic export requires an isolated runtime profile")
        }
        let application = try CanonicalAbsolutePath(configuration.appPath)
        let applicationSupportBase = try CanonicalAbsolutePath(
            applicationSupportBasePath
        )
        let homeDirectory = try CanonicalAbsolutePath(homeDirectoryPath)
        let expected = try expectedScope(
            profile: profile,
            application: application,
            applicationSupportBase: applicationSupportBase
        )
        let supplied = try [
            CanonicalAbsolutePath(configuration.databasePath),
            CanonicalAbsolutePath(configuration.repositoryLockPath),
            CanonicalAbsolutePath(configuration.exportPath),
            CanonicalAbsolutePath(configuration.sentinelsPath),
            CanonicalAbsolutePath(configuration.ledgerPath),
            CanonicalAbsolutePath(configuration.startGatePath)
        ]
        let required = [
            expected.database,
            expected.repositoryLock,
            expected.export,
            expected.sentinels,
            expected.ledger,
            expected.startGate
        ]
        guard supplied == required else {
            throw invalid(
                "diagnostic-export resources are outside the exact "
                    + "\(profile.rawValue) scope"
            )
        }

        let protectedRoots = try [
            applicationSupportBase.appending(
                NoonmarkRuntimeProfile.production.applicationSupportDirectoryName
            ),
            homeDirectory
                .appending("Library")
                .appending("Mobile Documents")
                .appending("com~apple~CloudDocs")
                .appending("Noonmark")
                .appending("SyncRepository")
        ]
        let controlledPaths = [
            expected.application,
            expected.database,
            expected.repositoryLock.parent,
            expected.export.parent,
            expected.ledger.parent
        ]
        for path in controlledPaths {
            for protectedRoot in protectedRoots {
                let overlapsProduction =
                    path.isSameOrDescendant(of: protectedRoot)
                        || protectedRoot.isSameOrDescendant(of: path)
                guard overlapsProduction == false else {
                    throw invalid(
                        "diagnostic-export scope overlaps production-owned data"
                    )
                }
            }
        }
        return expected
    }

    private static func expectedScope(
        profile: NoonmarkRuntimeProfile,
        application: CanonicalAbsolutePath,
        applicationSupportBase: CanonicalAbsolutePath
    ) throws -> Scope {
        switch profile {
        case .e2e:
            guard application.lastComponent == "NoonmarkE2E.app",
                  application.parent.lastComponent == "dist",
                  application.parent.parent.components.isEmpty == false
            else {
                throw invalid(
                    "diagnostic-export App is outside the exact e2e layout"
                )
            }
            let repositoryRoot = application.parent.parent
            let evidenceRoot = try repositoryRoot
                .appending("artifacts")
                .appending("e2e-diagnostic-closure")
            let controlRoot = try evidenceRoot.appending("helper")
            return Scope(
                application: application,
                database: try evidenceRoot.appending("Noonmark.sqlite"),
                repositoryLock: try evidenceRoot
                    .appending("SyncRepository")
                    .appending(".repository.lock"),
                export: try evidenceRoot.appending(
                    "Noonmark-Diagnostic-Closure.noonmarkdiagnostics"
                ),
                sentinels: try evidenceRoot.appending(
                    "privacy-sentinels.txt"
                ),
                ledger: try controlRoot.appending("ledger.tsv"),
                startGate: try controlRoot.appending(
                    "exit-observer-gate.txt"
                )
            )
        case .dmgValidation:
            let applicationsRoot = application.parent
            let workRoot = applicationsRoot.parent
            let artifactsRoot = workRoot.parent
            guard application.lastComponent == "NoonmarkDMGValidation.app",
                  applicationsRoot.lastComponent == "Applications",
                  workRoot.lastComponent == "dmg-install",
                  artifactsRoot.lastComponent == "artifacts"
            else {
                throw invalid(
                    "diagnostic-export App is outside the exact DMG validation layout"
                )
            }
            let dataRoot = try applicationSupportBase.appending(
                profile.applicationSupportDirectoryName
            )
            let controlRoot = try workRoot.appending("helper")
            return Scope(
                application: application,
                database: try dataRoot.appending("Noonmark.sqlite"),
                repositoryLock: try dataRoot
                    .appending("sync-repository")
                    .appending(".repository.lock"),
                export: try workRoot.appending(
                    "Noonmark-DMGValidation-Diagnostics.noonmarkdiagnostics"
                ),
                sentinels: try workRoot.appending(
                    "diagnostic-export-sentinels.txt"
                ),
                ledger: try controlRoot.appending("ledger.tsv"),
                startGate: try controlRoot.appending(
                    "exit-observer-gate.txt"
                )
            )
        case .production, .development, .demo, .audit:
            throw invalid("unsupported diagnostic-export runtime profile")
        }
    }

    private static func requiredLeaf(
        _ path: CanonicalAbsolutePath
    ) throws -> String {
        guard let leaf = path.lastComponent else {
            throw invalid("diagnostic-export resource has no file name")
        }
        return leaf
    }

    private static func invalid(
        _ reason: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .invalidArguments(reason)
    }
}
