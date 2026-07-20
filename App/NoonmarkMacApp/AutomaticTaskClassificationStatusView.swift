import NoonmarkCore
import NoonmarkMacUIContract
import SwiftUI

struct AutomaticTaskClassificationStatusView: View {
    @EnvironmentObject private var store: NoonmarkStore

    let chainID: TaskChainID
    let taskTitle: String
    let accessibilitySurface: MacUIAutomaticClassificationSurface
    let accessibilityInstanceID: String

    var body: some View {
        if let status = store.automaticClassificationStatus(for: chainID) {
            statusContent(status)
                .modifier(
                    AutomaticTaskClassificationStatusModifier(
                        identifier: accessibilityIdentifier(for: status),
                        label: store.copy.automaticClassificationStatusAccessibilityLabel(
                            statusText(status),
                            taskTitle: taskTitle
                        )
                    )
                )
        }
    }

    @ViewBuilder
    private func statusContent(
        _ status: AutomaticClassificationPresentationStatus
    ) -> some View {
        switch status {
        case .working:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                Text(store.copy.automaticClassificationWorking)
            }
        case .waitingForConfiguration:
            Text(store.copy.automaticClassificationWaitingForConfiguration)
        case .waitingForDecision:
            Text(store.copy.automaticClassificationWaitingForDecision)
        case .providerPaused:
            Button {
                store.retryAutomaticClassificationProviderCircuit()
            } label: {
                Text(store.copy.automaticClassificationProviderPaused)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.warn)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
        case .failed:
            Button {
                store.retryAutomaticClassification(for: chainID)
            } label: {
                Text(store.copy.automaticClassificationFailed)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.warn)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
        }
    }

    private func statusText(
        _ status: AutomaticClassificationPresentationStatus
    ) -> String {
        switch status {
        case .working:
            store.copy.automaticClassificationWorking
        case .waitingForConfiguration:
            store.copy.automaticClassificationWaitingForConfiguration
        case .waitingForDecision:
            store.copy.automaticClassificationWaitingForDecision
        case .providerPaused:
            store.copy.automaticClassificationProviderPaused
        case .failed:
            store.copy.automaticClassificationFailed
        }
    }

    private func accessibilityIdentifier(
        for status: AutomaticClassificationPresentationStatus
    ) -> String {
        switch status {
        case .providerPaused:
            MacUIAutomaticClassificationAccessibility.retryIdentifier(
                surface: accessibilitySurface,
                instanceID: accessibilityInstanceID,
                kind: .providerCircuit
            )
        case .failed:
            MacUIAutomaticClassificationAccessibility.retryIdentifier(
                surface: accessibilitySurface,
                instanceID: accessibilityInstanceID,
                kind: .job
            )
        case .working, .waitingForConfiguration, .waitingForDecision:
            MacUIAutomaticClassificationAccessibility.statusIdentifier(
                surface: accessibilitySurface,
                instanceID: accessibilityInstanceID
            )
        }
    }
}

private struct AutomaticTaskClassificationStatusModifier: ViewModifier {
    let identifier: String
    let label: String

    func body(content: Content) -> some View {
        content
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text3)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }
}
