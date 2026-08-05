import AppKit
import Foundation
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import UniformTypeIdentifiers

private extension UTType {
    static let noonmarkDiagnostics = UTType(
        exportedAs: "app.noonmark.diagnostics",
        conformingTo: .json
    )
}

private enum DiagnosticExportUIError: Error {
    case managedDiagnosticDestination
}

extension NoonmarkStore {
    var canManageLocalDiagnostics: Bool {
        localDiagnosticRecorder != nil && isDiagnosticActionRunning == false
    }

    func refreshDiagnosticHealth() {
        guard let localDiagnosticRecorder else {
            diagnosticHealth = nil
            return
        }
        Task { [weak self, localDiagnosticRecorder] in
            let health = await localDiagnosticRecorder.health()
            guard let self else { return }
            diagnosticHealth = health
        }
    }

    func exportDiagnostics() {
        guard let localDiagnosticRecorder,
              isDiagnosticActionRunning == false
        else { return }
        isDiagnosticActionRunning = true
        let operation = diagnostics.startOperation(kind: .diagnosticExport)
        operation.stage(.exportSnapshot)
        Task { [weak self, localDiagnosticRecorder] in
            guard let self else { return }
            do {
                let preview = try await localDiagnosticRecorder.preview()
                guard confirmDiagnosticExport(preview) else {
                    operation.succeed()
                    isDiagnosticActionRunning = false
                    return
                }
                let panel = NSSavePanel()
                panel.title = copy.diagnosticsExportPanelTitle
                panel.nameFieldStringValue = diagnosticExportFilename()
                panel.allowedContentTypes = [.noonmarkDiagnostics]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destinationURL = panel.url else {
                    operation.succeed()
                    isDiagnosticActionRunning = false
                    return
                }
                try validateDiagnosticExportDestination(destinationURL)

                operation.stage(.exportWrite)
                let receipt = try await withDiagnosticSecurityScope(
                    destinationURL
                ) {
                    try await localDiagnosticRecorder.export(
                        to: destinationURL
                    )
                }
                operation.succeed(
                    progress: DiagnosticProgress(
                        recordCount: receipt.recordCount,
                        byteCount: Int64(receipt.byteCount)
                    )
                )
                isDiagnosticActionRunning = false
                refreshDiagnosticHealth()
                showToast(copy.diagnosticsExportSucceeded)
            } catch {
                let incidentID = operation.fail(
                    AppDiagnosticFailureMapping.map(error)
                )
                isDiagnosticActionRunning = false
                presentDiagnosticActionFailure(
                    title: copy.diagnosticsExportFailedTitle,
                    incidentID: incidentID
                )
            }
        }
    }

    func clearDiagnostics() {
        guard let localDiagnosticRecorder,
              isDiagnosticActionRunning == false
        else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.diagnosticsClearTitle
        alert.informativeText = copy.diagnosticsClearMessage
        alert.addButton(withTitle: copy.clearDiagnostics)
        alert.addButton(withTitle: copy.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isDiagnosticActionRunning = true
        Task { [weak self, localDiagnosticRecorder] in
            guard let self else { return }
            do {
                try await localDiagnosticRecorder.clear()
                localDiagnosticRecorder.startSession()
                isDiagnosticActionRunning = false
                refreshDiagnosticHealth()
                showToast(copy.diagnosticsClearSucceeded)
            } catch {
                let incidentID = DiagnosticIncidentID()
                diagnostics.record(
                    .persistenceFailed(
                        failure: AppDiagnosticFailureMapping.map(error),
                        incidentID: incidentID
                    )
                )
                isDiagnosticActionRunning = false
                presentDiagnosticActionFailure(
                    title: copy.diagnosticsClearFailedTitle,
                    incidentID: incidentID
                )
            }
        }
    }

    func recordCleanDiagnosticShutdown() async {
        guard didRecordCleanDiagnosticShutdown == false else { return }
        didRecordCleanDiagnosticShutdown = true
        if let localDiagnosticRecorder {
            await localDiagnosticRecorder.recordCleanShutdown()
        } else {
            diagnostics.record(.cleanShutdown())
        }
    }

    func recordTerminationPersistenceFailure(code: Int) {
        diagnostics.record(
            .persistenceFailed(
                failure: DiagnosticFailure(
                    domain: .domainValidation,
                    code: code
                ),
                incidentID: DiagnosticIncidentID()
            )
        )
    }

    @discardableResult
    func recordOperationFailureEvidence(
        _ context: AppOperationFailureContext,
        error: Error,
        operationID: DiagnosticOperationID? = nil,
        incidentID existingIncidentID: DiagnosticIncidentID? = nil
    ) -> DiagnosticIncidentID {
        if context == .sync {
            if let existingIncidentID {
                return existingIncidentID
            }
            let operation = diagnostics.startOperation(
                kind: .localFirstSync
            )
            return operation.fail(diagnosticFailure(for: error))
        }
        let incidentID = existingIncidentID ?? DiagnosticIncidentID()
        if context.recordsPersistenceFailure {
            diagnostics.record(
                .persistenceFailed(
                    failure: diagnosticFailure(for: error),
                    incidentID: incidentID
                )
            )
        } else if let mutationContext = context.diagnosticMutationContext {
            diagnostics.record(
                .mutationRejected(
                    context: mutationContext,
                    reason: diagnosticMutationRejectionReason(
                        for: error,
                        context: context
                    ),
                    operationID: operationID ?? activeDiagnosticOperationID,
                    incidentID: incidentID,
                    failure: diagnosticFailure(for: error)
                )
            )
        }
        return incidentID
    }

    func diagnosticFailure(for error: Error) -> DiagnosticFailure {
        if let persistenceError = error as? EnginePersistenceCommitError {
            return AppDiagnosticFailureMapping.map(
                persistenceError.underlying
            )
        }
        return AppDiagnosticFailureMapping.map(error)
    }

    private var activeDiagnosticOperationID: DiagnosticOperationID? {
        guard case let .localFirstSync(operationID) = exclusiveEngineOperation
        else { return nil }
        return DiagnosticOperationID(rawValue: operationID)
    }

    private func diagnosticMutationRejectionReason(
        for error: Error,
        context: AppOperationFailureContext
    ) -> DiagnosticMutationRejectionReason {
        if let gateError = error as? StoreMutationGateError {
            switch gateError {
            case .exclusiveOperationInProgress:
                return .exclusiveOperationInProgress
            case .pendingZhulongApplication:
                return .pendingApplicationRecovery
            }
        }
        if error is NaturalDayMutationError || context == .naturalDay {
            return .invalidNaturalDay
        }
        if error is EnginePersistenceCommitError {
            return .persistenceFailure
        }
        return .domainRule
    }

    private func confirmDiagnosticExport(
        _ preview: DiagnosticExportPreview
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.diagnosticsPreviewTitle
        alert.informativeText = copy.diagnosticExportPreview(preview)
        alert.addButton(withTitle: copy.diagnosticsPreviewContinue)
        alert.addButton(withTitle: copy.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func diagnosticExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Noonmark-Diagnostics-\(formatter.string(from: Date())).noonmarkdiagnostics"
    }

    private func validateDiagnosticExportDestination(_ url: URL) throws {
        guard let databaseURL else { return }
        let diagnosticRoot = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let destinationParent = url
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = diagnosticRoot.path
        let parentPath = destinationParent.path
        guard parentPath != rootPath,
              parentPath.hasPrefix(rootPath + "/") == false
        else {
            throw DiagnosticExportUIError.managedDiagnosticDestination
        }
    }

    private func withDiagnosticSecurityScope<Result>(
        _ url: URL,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    private func presentDiagnosticActionFailure(
        title: String,
        incidentID: DiagnosticIncidentID
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = copy.diagnosticIncidentLabel(incidentID)
        alert.addButton(withTitle: copy.dismiss)
        alert.runModal()
    }
}

private extension AppOperationFailureContext {
    var diagnosticMutationContext: DiagnosticMutationContext? {
        switch self {
        case .taskMutation, .naturalDay:
            .task
        case .noteMutation:
            .note
        case .ideaMutation:
            .idea
        case .dailyReview:
            .dailyReview
        case .preferences:
            .preferences
        case .provider:
            .provider
        case .undo:
            .undo
        case .redo:
            .redo
        case .persistence, .sync, .dataTransfer, .databaseLoad:
            nil
        }
    }

    var recordsPersistenceFailure: Bool {
        switch self {
        case .persistence, .dataTransfer, .databaseLoad:
            true
        case .taskMutation, .noteMutation, .ideaMutation, .dailyReview,
             .preferences, .sync, .provider, .undo, .redo, .naturalDay:
            false
        }
    }
}
