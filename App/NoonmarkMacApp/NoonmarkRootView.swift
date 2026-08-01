import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

final class NoonmarkWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}

extension NSWindow {
    func enableNoonmarkDynamicKeyViewLoop() {
        autorecalculatesKeyViewLoop = true
    }
}

enum TaskClassificationDisplay: Equatable {
    case current(TaskClassificationProjection)
    case historical(
        TraceClassificationProjection,
        categoryPresentation: ClassificationItemProjection? = nil
    )

    var category: ClassificationItemProjection? {
        switch self {
        case let .current(projection):
            projection.category
        case let .historical(projection, categoryPresentation):
            categoryPresentation ?? projection.category
        }
    }

    var labels: [ClassificationItemProjection] {
        switch self {
        case let .current(projection):
            projection.labels
        case let .historical(projection, _):
            projection.labels
        }
    }

    var isHistorical: Bool {
        if case .historical = self { return true }
        return false
    }

    var isEmpty: Bool {
        category == nil && labels.isEmpty
    }
}

struct OperationFailureBanner: View {
    let message: String
    let diagnosticIncidentLabel: String?
    let dismissTitle: String
    let accessibilityIdentifier: String
    let bottomPadding: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.noonmarkSystem(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diagnosticIncidentLabel {
                        Text(diagnosticIncidentLabel)
                        .font(.noonmarkSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    }
                }
                Spacer(minLength: 8)
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 620)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.warnSoft)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, bottomPadding)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .background {
                AppE2EViewAnchor(
                    identifier: accessibilityIdentifier,
                    verificationText: message
                )
            }
        }
    }
}

struct NoonmarkRootView: View {
    @EnvironmentObject private var store: NoonmarkStore
    let workspaceStateRepository: WorkspaceStateRepository

    var body: some View {
        ZStack {
            NativeWorkspaceSplitView(
                store: store,
                stateRepository: workspaceStateRepository
            )
            .ignoresSafeArea(.container, edges: .top)
            .background(Theme.background)
            .disabled(
                store.showingClassificationManager
                    || store.dayBoundaryState.isReady == false
            )
            .accessibilityHidden(store.showingClassificationManager)

            if let message = store.dayBoundaryState.failureMessage {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.copy.naturalDayBlockedTitle)
                                .font(.noonmarkSystem(size: 12, weight: .semibold))
                            Text(message)
                                .font(.noonmarkSystem(size: 11))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        Button(store.copy.retry) {
                            store.retryNaturalDay()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.warnSoft)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.warn.opacity(0.28)).frame(height: 1)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(store.copy.naturalDayBlockedTitle)
                .zIndex(2)
            }

            if let operationFailure = store.operationFailureNotice {
                OperationFailureBanner(
                    message: operationFailure.message,
                    diagnosticIncidentLabel: operationFailure
                        .diagnosticIncidentID.map(
                            store.copy.diagnosticIncidentLabel
                        ),
                    dismissTitle: store.copy.dismiss,
                    accessibilityIdentifier: "app.operation-failure",
                    bottomPadding: 76
                ) {
                    store.dismissOperationFailure()
                }
                .zIndex(3)
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.noonmarkSystem(size: 12, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.text1))
                        .shadow(color: Theme.shadowRaised, radius: 16, y: 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 30)
                        .accessibilityIdentifier("app.toast")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "app.toast",
                                verificationText: toast
                            )
                        }
                }
            }
        }
        .animation(
            Theme.shouldReduceMotion
                ? nil
                : .easeOut(duration: MacUIAnimationMetrics.toastRiseDuration),
            value: store.toast
        )
        .font(.noonmarkSystem(size: 13))
        .sheet(isPresented: $store.showingClassificationManager) {
            ClassificationManagementDialog {
                store.showingClassificationManager = false
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $store.showingTaskCycleCreation) {
            TaskCycleCreationSheet()
                .environmentObject(store)
        }
        .sheet(item: $store.showingPicker) { purpose in
            DatePickerSheet(purpose: purpose)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showingFromPoolPicker) {
            FromPoolSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showingChangeDialog) {
            ChangeTaskSheet()
                .environmentObject(store)
        }
        .sheet(item: Binding(
            get: { store.preparedDataImport },
            set: { if $0 == nil { store.cancelPreparedDataImport() } }
        )) { preview in
            DataImportConfirmationSheet(preview: preview)
                .environmentObject(store)
        }
        .onMoveCommand { direction in
            if store.showingClassificationManager == false, store.selectedWorkspaceItemCount == 0 {
                store.moveSelectedDate(direction)
            }
        }
        .onAppear {
            syncNativeWindowTitle()
            if store.showingClassificationManager {
                resignBackgroundFocus()
            }
        }
        .onChange(of: store.showingClassificationManager) { _, isPresented in
            if isPresented {
                resignBackgroundFocus()
            }
        }
        .onChange(of: store.windowTitle) { _, _ in
            syncNativeWindowTitle()
        }
        .onChange(of: store.isZhulongEnabled) { _, _ in
            store.ensureVisiblePage()
        }
        .onChange(of: store.toast) { _, message in
            guard let message else { return }
            announce(message)
        }
        .onChange(of: store.operationFailureNotice) { _, notice in
            guard let notice else { return }
            announce(notice.message)
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func syncNativeWindowTitle() {
        NSApp.windows.first { $0 is NoonmarkWindow }?.title = store.windowTitle
    }

    private func resignBackgroundFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}
