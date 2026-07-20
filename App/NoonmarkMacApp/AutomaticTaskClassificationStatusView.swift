import NoonmarkCore
import SwiftUI

struct AutomaticTaskClassificationStatusView: View {
    @EnvironmentObject private var store: NoonmarkStore

    let chainID: TaskChainID
    let taskTitle: String

    var body: some View {
        if let status = store.automaticClassificationStatus(for: chainID) {
            statusContent(status)
                .font(.noonmarkSystem(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "automatic-classification.status.\(chainID.description)"
                )
                .accessibilityLabel(
                    store.copy.automaticClassificationStatusAccessibilityLabel(
                        statusText(status),
                        taskTitle: taskTitle
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
            .accessibilityIdentifier(
                "automatic-classification.status.\(chainID.description).circuit-retry"
            )
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
}
