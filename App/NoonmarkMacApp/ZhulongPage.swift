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

struct ZhulongPage: View {
    var body: some View {
        ZhulongConvergedHome()
    }
}

struct ZhulongProviderKindPicker: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var selection: AIProviderKind

    var body: some View {
        Picker("", selection: $selection) {
            ForEach([AIProviderKind.openAICompatible, .localModel, .customHTTP], id: \.self) { kind in
                Text(label(for: kind)).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }

    func label(for kind: AIProviderKind) -> String {
        switch kind {
        case .openAICompatible:
            return "OpenAI-compatible"
        case .localModel:
            return store.copy.localModel
        case .customHTTP:
            return store.copy.customHTTP
        }
    }
}

struct ZhulongProviderTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            NativeSettingsTextField(
                text: $text,
                placeholder: placeholder,
                identifier: accessibilityIdentifier,
                accessibilityLabel: label
            )
            .frame(maxWidth: .infinity)
        }
    }
}

struct ZhulongProviderSecureField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let hasStoredValue: Bool
    @State private var localText: String

    init(
        label: String,
        text: Binding<String>,
        placeholder: String,
        hasStoredValue: Bool
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.hasStoredValue = hasStoredValue
        _localText = State(initialValue: text.wrappedValue)
    }

    private var displayedPlaceholder: String {
        text.isEmpty && hasStoredValue ? "••••••••••••" : placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            NativeSettingsSecureField(
                text: $localText,
                placeholder: displayedPlaceholder,
                identifier: "settings.zhulong.provider.api-key",
                accessibilityLabel: label,
                onEndEditing: { text = $0 }
            )
            .frame(maxWidth: .infinity)
        }
        .onChange(of: text) { _, persistedText in
            if localText != persistedText {
                localText = persistedText
            }
        }
    }
}

struct ZhulongProviderField: View {
    let label: String
    let value: String
    var last = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
            Spacer()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if last == false {
                RailDivider()
            }
        }
    }
}

struct ZhulongScopeChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
