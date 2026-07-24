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

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case groups
    case data
    case sync
    case zhulong
    case privacy

    var id: String { rawValue }

    func title(copy: AppCopy) -> String {
        switch self {
        case .general: copy.preferencesTitle
        case .groups: copy.organizationTitle
        case .data: copy.dataSectionTitle
        case .sync: copy.syncTitle
        case .zhulong: copy.providerTitle
        case .privacy: copy.privacyTitle
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .groups: "square.grid.2x2"
        case .data: "square.and.arrow.up.on.square"
        case .sync: "arrow.triangle.2.circlepath"
        case .zhulong: "sparkles"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsPaneContent: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch pane {
            case .general:
                SettingsPreferenceCard()
            case .groups:
                GroupManagementSettingsCard()
            case .data:
                SettingsDataCard()
            case .sync:
                SettingsSyncCard()
            case .zhulong:
                SettingsProviderOverviewCard()
            case .privacy:
                SettingsPrivacyCard()
            }
        }
    }
}

struct SettingsPreferenceCard: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var poemIsExpanded = AppLaunchArguments.contains(
        "--e2e-expand-settings-poem"
    )

    private var poemTextBinding: Binding<String> {
        Binding(
            get: { store.engine.preferences.settingsPoemDisplayPolicy.text },
            set: { store.setSettingsPoemText($0) }
        )
    }

    private var poemEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.engine.preferences.settingsPoemDisplayPolicy.enabled },
            set: { store.setSettingsPoemEnabled($0) }
        )
    }

    var body: some View {
        SettingsCard(subtitle: store.copy.preferencesSubtitle) {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(title: store.copy.appearanceTitle) {
                    SegmentedPair(
                        left: store.copy.coolGray,
                        right: store.copy.warmPaper,
                        leftSelected: store.engine.preferences.theme == .coolGray,
                        leftAction: { store.setTheme(.coolGray) },
                        rightAction: { store.setTheme(.warmPaper) },
                        identifier: "settings.preferences.theme"
                    )
                }
                SettingSection(title: store.copy.languageTitle) {
                    SegmentedPair(
                        left: store.copy.chineseLanguage,
                        right: store.copy.englishLanguage,
                        leftSelected: store.engine.preferences.language == .chinese,
                        leftAction: { store.setLanguage(.chinese) },
                        rightAction: { store.setLanguage(.english) },
                        identifier: "settings.preferences.language"
                    )
                }
                SettingSection(title: store.copy.swipeDirectionTitle) {
                    SegmentedPair(
                        left: store.copy.bookSwipeDirection,
                        right: store.copy.reversedSwipeDirection,
                        leftSelected: store
                            .horizontalPageNavigationSwipeDirection == .book,
                        leftAction: {
                            store.setHorizontalPageNavigationSwipeDirection(
                                .book
                            )
                        },
                        rightAction: {
                            store.setHorizontalPageNavigationSwipeDirection(
                                .reversed
                            )
                        },
                        identifier: "settings.preferences.swipe-direction"
                    )
                    Text(store.copy.swipeDirectionExplanation)
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(
                    store.copy.settingsPoemTitle,
                    isExpanded: $poemIsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(store.copy.settingsPoemDisplay, isOn: poemEnabledBinding)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier(
                                "settings.preferences.poem.enabled"
                            )
                        HStack(spacing: 8) {
                            Text(store.copy.settingsPoemEditorTitle)
                                .font(.noonmarkSystem(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                            Spacer()
                            SmallActionButton(store.copy.resetSettingsPoem) {
                                store.resetSettingsPoemText()
                            }
                        }
                        MarkdownEditor(
                            text: poemTextBinding,
                            placeholder: store.copy.settingsPoemPlaceholder,
                            style: .body,
                            height: 120
                        )
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    }
                    .padding(.top, 8)
                }
                .font(.noonmarkSystem(size: 12.5, weight: .medium))
            }
        }
    }
}

struct SettingsDataCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        SettingsCard(subtitle: store.copy.dataSectionSubtitle) {
            HStack(spacing: 8) {
                SmallActionButton(store.copy.exportJSON, tone: .accent) { store.exportDataPackage() }
                SmallActionButton(store.copy.importData) { store.importDataPackage() }
            }
        }
    }
}

struct SettingsSyncCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        SettingsCard(subtitle: store.copy.syncSubtitle) {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(title: store.copy.dataModeTitle) {
                    SegmentedPair(
                        left: store.copy.localFirstMode,
                        right: store.copy.onlineFirstMode,
                        leftSelected: store.engine.preferences.dataMode == .localFirst,
                        leftAction: { store.setDataMode(.localFirst) },
                        rightAction: { store.setDataMode(.onlineFirst) },
                        identifier: "settings.sync.data-mode"
                    )
                    Text(store.copy.dataModeBoundary)
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.engine.preferences.dataMode == .localFirst {
                    LocalFirstCloudSyncCard()
                } else {
                    ScheduledBackupCard()
                }
            }
        }
    }
}

struct LocalFirstCloudSyncCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var policy: LocalFirstCloudSyncPolicy {
        store.engine.preferences.localFirstSyncPolicy
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { policy.enabled },
            set: { enabled in store.setLocalFirstSyncEnabled(enabled) }
        )
    }

    private var runtimeStatus: (text: String, color: Color) {
        let iCloudIsUnavailable = policy.endpoint == .iCloud
            && store.isICloudSyncEndpointAvailable == false
        if iCloudIsUnavailable {
            return (store.copy.unavailable, Theme.warn)
        }
        if policy.enabled {
            return (store.copy.available, Theme.ok)
        }
        return (store.copy.localFirstSyncDisabled, Theme.text3)
    }

    private var displayedCloudKitConfiguration: CloudKitSyncLaunchConfiguration? {
        guard policy.endpoint == .iCloud else { return nil }
        return store.cloudKitSyncConfiguration
    }

    var body: some View {
        SettingSection(title: store.copy.localFirstSyncTitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Toggle(store.copy.localFirstSyncEnabled, isOn: syncEnabledBinding)
                        .toggleStyle(.checkbox)
                        .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    StatusPill(text: runtimeStatus.text, color: runtimeStatus.color)
                    Spacer()
                }
                SettingSection(title: store.copy.syncEndpointTitle) {
                    SegmentedOptionRow(
                        options: CloudSyncEndpointKind.allCases,
                        selected: policy.endpoint,
                        title: store.copy.cloudSyncEndpointTitle(for:),
                        action: store.setLocalFirstSyncEndpoint
                    )
                }
                SettingSection(title: store.copy.syncModeTitle) {
                    SegmentedPair(
                        left: store.copy.syncManualMode,
                        right: store.copy.syncAutomaticMode,
                        leftSelected: policy.mode == .manual,
                        leftAction: { store.setLocalFirstSyncMode(.manual) },
                        rightAction: { store.setLocalFirstSyncMode(.automatic) },
                        identifier: "settings.sync.mode"
                    )
                }
                if policy.mode == .automatic {
                    SettingsInfoRow(
                        label: store.copy.syncAutomaticIntervalTitle,
                        value: store.copy.syncAutomaticInterval(policy.intervalSeconds),
                        last: true
                    )
                }
                if policy.endpoint == .iCloud || policy.endpoint == .localFolder {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SmallActionButton(
                                store.isLocalFirstSyncing ? store.copy.syncing : store.copy.syncNow,
                                tone: .accent
                            ) {
                                store.syncLocalFolderNow()
                            }
                            .disabled(
                                store.isLocalFirstSyncing
                                    || policy.enabled == false
                                    || (policy.endpoint == .iCloud
                                        && store.isICloudSyncEndpointAvailable == false)
                            )
                            Text(
                                policy.enabled
                                    ? (policy.endpoint == .iCloud
                                        ? (store.isCloudKitSyncConfigured
                                            ? store.copy.cloudKitSyncReady
                                            : store.copy.iCloudSyncReady)
                                        : store.copy.localFolderSyncReady)
                                    : store.copy.localFirstSyncDisabled
                            )
                                .font(.noonmarkSystem(size: 11.5))
                                .foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let configuration = displayedCloudKitConfiguration {
                            SettingsInfoRow(
                                label: store.copy.cloudKitContainerTitle,
                                value: configuration.containerIdentifier
                            )
                            SettingsInfoRow(
                                label: store.copy.cloudKitZoneTitle,
                                value: configuration.zoneName,
                                last: store.localFirstSyncMessage == nil
                            )
                        } else if let endpointURL = NoonmarkStore.configuredLocalFirstSyncEndpointURL(for: policy.endpoint) {
                            if policy.endpoint == .iCloud {
                                SettingsInfoRow(
                                    label: store.copy.iCloudDriveLocationTitle,
                                    value: store.copy.iCloudDriveLogicalLocation
                                )
                                SettingsInfoRow(
                                    label: store.copy.localCachePathTitle,
                                    value: endpointURL.path,
                                    last: store.localFirstSyncMessage == nil
                                )
                            } else {
                                SettingsInfoRow(
                                    label: store.copy.syncFolderPathTitle,
                                    value: endpointURL.path,
                                    last: store.localFirstSyncMessage == nil
                                )
                            }
                        } else {
                            SettingsInfoRow(
                                label: policy.endpoint == .iCloud ? store.copy.iCloudDriveLocationTitle : store.copy.syncFolderPathTitle,
                                value: store.copy.iCloudDriveUnavailable,
                                last: store.localFirstSyncMessage == nil
                            )
                        }
                        if let message = store.localFirstSyncMessage {
                            Text(message)
                                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                } else {
                    Notice(text: store.copy.remoteEndpointPlanned, tone: .locked)
                }
                Text(store.copy.localFirstSyncBoundary)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ScheduledBackupCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        SettingSection(title: store.copy.scheduledBackupTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Notice(text: store.copy.planned, tone: .locked)
                Text(store.copy.backupBoundary)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SyncOptionsCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.engine.syncEndpointOptions().enumerated()), id: \.element.kind) { index, option in
                let iCloudUnavailable = option.kind == .iCloud
                    && store.isICloudSyncEndpointAvailable == false
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.copy.syncTitle(for: option.kind))
                            .font(.noonmarkSystem(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        Text(store.copy.syncDescription(for: option.kind))
                            .font(.noonmarkSystem(size: 11.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    StatusPill(
                        text: iCloudUnavailable
                            ? store.copy.unavailable
                            : store.copy.syncAvailabilityTitle(for: option.availability),
                        color: iCloudUnavailable
                            ? Theme.warn
                            : (option.availability == .available ? Theme.ok : Theme.text3)
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if index < store.engine.syncEndpointOptions().count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct SettingsProviderOverviewCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var status: (text: String, color: Color) {
        if store.zhulongProviderDraft.isConfigured,
           store.zhulongProviderDraft.hasStoredAPIKey
        {
            return (store.copy.providerConfigured, Theme.ok)
        }
        if store.zhulongProviderDraft.enabled {
            return (store.copy.providerIncomplete, Theme.warn)
        }
        return (store.copy.providerDisabled, Theme.text3)
    }

    var body: some View {
        SettingsCard(subtitle: store.copy.providerSubtitle) {
            VStack(alignment: .leading, spacing: 22) {
                SettingSection(title: store.copy.providerConfigurationTitle) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Text(store.copy.enableProvider)
                                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                                    .accessibilityHidden(true)
                                NativeSettingsSwitch(
                                    isOn: $store.zhulongProviderDraft.enabled,
                                    identifier: "settings.zhulong.provider.enabled",
                                    accessibilityLabel: store.copy.enableProvider
                                )
                            }
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "settings.zhulong.provider.enabled.anchor",
                                    verificationText: store.zhulongProviderDraft.enabled ? "enabled" : "disabled"
                                )
                            }
                            StatusPill(text: status.text, color: status.color)
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text(store.copy.providerType)
                                .font(.noonmarkSystem(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                            ZhulongProviderKindPicker(selection: $store.zhulongProviderDraft.kind)
                        }

                        SettingsFormRows {
                            ZhulongProviderTextField(
                                label: store.copy.providerName,
                                text: $store.zhulongProviderDraft.displayName,
                                placeholder: store.copy.customProvider,
                                accessibilityIdentifier: "settings.zhulong.provider.name"
                            )
                            ZhulongProviderTextField(
                                label: store.copy.baseURLLabel,
                                text: $store.zhulongProviderDraft.baseURL,
                                placeholder: "https://api.example.com/v1",
                                accessibilityIdentifier: "settings.zhulong.provider.base-url"
                            )
                            ZhulongProviderTextField(
                                label: store.copy.providerModel,
                                text: $store.zhulongProviderDraft.model,
                                placeholder: "gpt-4.1-mini / llama3.1",
                                accessibilityIdentifier: "settings.zhulong.provider.model"
                            )
                            ZhulongProviderSecureField(
                                label: store.copy.apiKeyLabel,
                                text: $store.zhulongProviderDraft.apiKeyInput,
                                placeholder: store.copy.apiKeyPlaceholder,
                                hasStoredValue: store.zhulongProviderDraft.hasStoredAPIKey
                            )
                        }

                        HStack(spacing: 8) {
                            providerActionButton(
                                store.copy.save,
                                tone: .accent,
                                identifier: "settings.zhulong.provider.save"
                            ) {
                                store.saveZhulongProvider()
                            }
                            providerActionButton(
                                store.copy.testConnection,
                                identifier: "settings.zhulong.provider.test"
                            ) {
                                store.testZhulongProvider()
                            }
                            providerActionButton(
                                store.copy.clear,
                                tone: .warn,
                                identifier: "settings.zhulong.provider.clear"
                            ) {
                                store.clearZhulongProvider()
                            }
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                }

                SettingSection(title: store.copy.zhulongFeaturesTitle) {
                    VStack(alignment: .leading, spacing: 14) {
                        featureToggle(
                            title: store.copy.enableZhulongPage,
                            description: store.copy.zhulongPageSwitchDescription,
                            isOn: Binding(
                                get: { store.isZhulongEnabled },
                                set: { store.setZhulongPageEnabled($0) }
                            ),
                            identifier: "settings.zhulong.page.enabled"
                        )
                        Divider()
                        featureToggle(
                            title: store.copy.enableAutomaticClassification,
                            description: store.copy.automaticClassificationSwitchDescription,
                            isOn: Binding(
                                get: { store.isAutomaticClassificationEnabled },
                                set: { store.setAutomaticClassificationEnabled($0) }
                            ),
                            identifier: "settings.zhulong.automatic-classification.enabled"
                        )
                    }
                }

                if store.isAutomaticClassificationEnabled {
                    HStack(spacing: 8) {
                        Image(
                            systemName: store.automaticClassificationCircuitPresentation == nil
                                ? (store.zhulongProviderDraft.hasStoredAPIKey ? "checkmark.circle" : "exclamationmark.circle")
                                : "pause.circle"
                        )
                        .foregroundStyle(
                            store.automaticClassificationCircuitPresentation != nil
                                ? Theme.warn
                                : (store.zhulongProviderDraft.hasStoredAPIKey ? Theme.ok : Theme.text3)
                        )
                        Text(providerStatusMessage)
                            .font(.noonmarkSystem(size: 11.5))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(2)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "settings.zhulong.automatic-classification-circuit"
                    )

                    if store.automaticClassificationCircuitPresentation != nil {
                        HStack {
                            SmallActionButton(
                                store.copy.retryAutomaticClassificationProvider
                            ) {
                                store.retryAutomaticClassificationProviderCircuit()
                            }
                            .accessibilityIdentifier(
                                "settings.zhulong.automatic-classification-circuit.retry"
                            )
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "settings.zhulong.automatic-classification-circuit.retry",
                                    verificationText: store.copy
                                        .retryAutomaticClassificationProvider
                                )
                            }
                            Spacer()
                        }
                    }
                }

                if let prompt = store.automaticClassificationBacklogPrompt {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                        .accessibilityHidden(true)

                    AutomaticClassificationBacklogPromptView(
                        count: prompt.count
                    )
                }
            }
        }
    }

    private var providerStatusMessage: String {
        guard let circuit = store.automaticClassificationCircuitPresentation else {
            return store.zhulongProviderStatusMessage
        }
        return store.copy.automaticClassificationCircuitMessage(
            circuit.waitingCount,
            failureCode: circuit.failureCode
        )
    }

    /// Provider credentials are security-sensitive settings, so their actions
    /// deliberately use one native control each. This makes the visible
    /// control, its AppKit accessibility identity, and its hit target the
    /// same object for VoiceOver and the real-App E2E path.
    private func providerActionButton(
        _ title: String,
        tone: SmallActionButton.Tone = .normal,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        NativeSmallActionButton(
            title: title,
            tone: tone,
            identifier: identifier,
            accessibilityLabel: title,
            action: action
        )
        .fixedSize(horizontal: true, vertical: false)
        .hoverSurface(
            cornerRadius: 6,
            idleFill: Theme.controlFill,
            hoverFill: Theme.listRowHover,
            idleStroke: Theme.line.opacity(0.72),
            hoverStroke: Theme.line2.opacity(0.72)
        )
    }

    private func featureToggle(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.noonmarkSystem(size: 12.5, weight: .medium))
                .background {
                    AppE2EViewAnchor(
                        identifier: identifier,
                        verificationText: isOn.wrappedValue ? "enabled" : "disabled"
                    )
                }
            Text(description)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AutomaticClassificationBacklogPromptView: View {
    @EnvironmentObject private var store: NoonmarkStore

    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.copy.automaticClassificationBacklogTitle(count))
                .font(.noonmarkSystem(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text1)

            Text(store.copy.automaticClassificationBacklogExplanation)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                backlogButton(
                    store.copy.startAutomaticClassificationBacklog(count),
                    accessibilityLabel: store.copy
                        .startAutomaticClassificationBacklogAccessibilityLabel(
                            count
                        ),
                    identifier: "start",
                    tone: .accent
                ) {
                    store.resolveAutomaticClassificationBacklog(.startExisting)
                }
                backlogButton(
                    store.copy.classifyOnlyFutureTasks,
                    accessibilityLabel: store.copy
                        .classifyOnlyFutureTasksAccessibilityLabel(count),
                    identifier: "future-only"
                ) {
                    store.resolveAutomaticClassificationBacklog(.futureOnly)
                }
                backlogButton(
                    store.copy.decideAutomaticClassificationBacklogLater,
                    accessibilityLabel: store.copy
                        .decideAutomaticClassificationBacklogLaterAccessibilityLabel(
                            count
                        ),
                    identifier: "later"
                ) {
                    store.resolveAutomaticClassificationBacklog(.later)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "settings.zhulong.automatic-classification-backlog"
        )
        .accessibilityLabel(
            store.copy.automaticClassificationBacklogTitle(count)
        )
        .accessibilityValue(
            store.copy.automaticClassificationBacklogAccessibilityValue(count)
        )
    }

    private func backlogButton(
        _ title: String,
        accessibilityLabel: String,
        identifier: String,
        tone: SmallActionButton.Tone = .normal,
        action: @escaping () -> Void
    ) -> some View {
        let fullIdentifier =
            "settings.zhulong.automatic-classification-backlog.\(identifier)"
        return NativeSmallActionButton(
            title: title,
            tone: tone,
            identifier: fullIdentifier,
            accessibilityLabel: accessibilityLabel,
            action: action
        )
        .fixedSize(horizontal: true, vertical: false)
        .hoverSurface(
            cornerRadius: 6,
            idleFill: Theme.controlFill,
            hoverFill: Theme.listRowHover,
            idleStroke: Theme.line.opacity(0.72),
            hoverStroke: Theme.line2.opacity(0.72)
        )
    }
}

struct SettingsFormRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
    }
}

struct SettingsPrivacyCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        SettingsCard(subtitle: store.copy.privacySubtitle) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsBoundaryRow(color: Theme.accent, text: store.copy.privacyRows[0])
                SettingsBoundaryRow(color: Theme.warn, text: store.copy.privacyRows[1])
                SettingsBoundaryRow(color: Theme.ok, text: store.copy.privacyRows[2])
                SettingsBoundaryRow(color: Theme.text3, text: store.copy.privacyRows[3])
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(subtitle)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsMetricPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var last = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            if last == false {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

struct SettingsBoundaryRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
    }
}
