import NoonmarkMacRuntime
import NoonmarkZhulong
import SwiftUI

struct ZhulongWorkspaceRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.selectedSession == nil ? copy.workspaceTitle : copy.currentSessionTitle)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)

            if let session = workspace.selectedSession {
                sessionInspector(session)
            } else {
                Text(copy.workspaceEmptyDescription)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            railDivider
            memoryInspector

            if let latest = workspace.records(using: copy).last {
                railDivider
                DetailSection(copy.latestEventTitle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latest.eyebrow)
                            .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                        Text(latest.title)
                            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(copy.eventTimestamp(latest.occurredAt))
                            .font(.noonmarkSystem(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("zhulong-workspace-rail")
    }

    private func sessionInspector(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection(copy.currentIntentTitle) {
                Text(session.primaryIntent)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            railDivider
            DetailSection(copy.dataScopeTitle) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            railDivider
            DetailSection(copy.providerBoundaryTitle) {
                VStack(alignment: .leading, spacing: 4) {
                    if let identity =
                        session.providerSends.last?.providerIdentity
                        ?? session.authorization?.providerIdentity
                    {
                        Text(identity.providerID)
                            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(
                            providerDisclosure(identity)
                        )
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(identity.location == .local ? Theme.ok : Theme.warn)
                    } else {
                        Text(copy.noProviderIdentity)
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                    Text(copy.providerReauthorizationNotice)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var memoryInspector: some View {
        DetailSection(copy.memoryTitle) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    copy.allowConfirmedMemory,
                    isOn: Binding(
                        get: { workspace.memoryLedger.isEnabled },
                        set: { enabled in workspace.setMemoryEnabled(enabled) }
                    )
                )
                .toggleStyle(.switch)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .accessibilityIdentifier("zhulong-memory-enabled")
                Text(
                    workspace.memoryLedger.isEnabled
                        ? copy.enabledMemoryDetail(count: workspace.memoryLedger.usableMemories.count)
                        : copy.disabledMemoryDetail
                )
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        copy.scopeTitle(scope.presentationCopyKey)
    }

    private func providerDisclosure(
        _ identity: ZhulongProviderConfigurationIdentity
    ) -> String {
        guard identity.location == .remote else {
            return copy.localProcessing
        }
        let endpoint = identity.baseURL
            .flatMap {
                URLComponents(
                    url: $0,
                    resolvingAgainstBaseURL: false
                )?.host
            }
            ?? identity.providerID
        return copy.remoteRecipient(
            endpoint: endpoint,
            model: identity.model
        )
    }
}
