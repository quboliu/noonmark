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

struct DetailHeader<Trailing: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)
            Spacer()
            trailing
            IconButton(systemName: "xmark", action: onClose)
        }
    }
}

extension DetailHeader where Trailing == EmptyView {
    init(_ title: String, onClose: @escaping () -> Void) {
        self.init(title, onClose: onClose) {
            EmptyView()
        }
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .frame(
                    width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                    height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.clear))
    }
}

struct IconMenuButton<Content: View>: View {
    let accessibilityIdentifier: String?
    @ViewBuilder let menuContent: Content

    init(
        accessibilityIdentifier: String? = nil,
        @ViewBuilder menuContent: () -> Content
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.menuContent = menuContent()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .frame(
                    width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                    height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(Theme.text3)
        .background {
            if let accessibilityIdentifier {
                AppE2EViewAnchor(
                    identifier: accessibilityIdentifier
                )
            }
        }
    }
}

struct DetailTitleRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MarkdownText(title)
                .font(.noonmarkSystem(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .padding(.top, 1)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DetailTitleRow where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) {
            EmptyView()
        }
    }
}

struct EditableDetailTitleRow<Trailing: View>: View {
    @EnvironmentObject private var store: NoonmarkStore
    let ownerID: String
    let title: String
    let editable: Bool
    let onCommit: @MainActor (String) async -> Bool
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        ownerID: String,
        editable: Bool,
        onCommit: @escaping @MainActor (String) async -> Bool,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.ownerID = ownerID
        self.title = title
        self.editable = editable
        self.onCommit = onCommit
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if editable {
                AutosavingMarkdownEditor(
                    ownerID: ownerID,
                    persistedText: title,
                    placeholder: store.copy.taskTitlePlaceholder,
                    style: .title,
                    showsSurface: false,
                    persistencePolicy: .nonemptyTrimmed,
                    onPersist: onCommit,
                    nativeAccessibilityIdentifier:
                    "detail.title"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(title, fallback: store.copy.untitledTask)
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            trailing
                .padding(.top, 1)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EditableDetailTitleRow where Trailing == EmptyView {
    init(
        _ title: String,
        ownerID: String,
        editable: Bool,
        onCommit: @escaping @MainActor (String) async -> Bool
    ) {
        self.init(
            title,
            ownerID: ownerID,
            editable: editable,
            onCommit: onCommit
        ) {
            EmptyView()
        }
    }
}

struct DetailPrimaryText<Title: View, Description: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let description: Description

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: NoonmarkVisualMetrics.detailTitleDescriptionSpacing
        ) {
            title
            description
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailDescriptionBlock: View {
    @EnvironmentObject private var store: NoonmarkStore
    let ownerID: String
    let text: String
    let placeholder: String
    let editable: Bool
    let onPersist: @MainActor (String) async -> Bool

    var body: some View {
        EditableDetailText(
            ownerID: ownerID,
            text: text,
            placeholder: placeholder,
            editable: editable,
            warm: false,
            fallback: store.copy.missingTaskDescription,
            onPersist: onPersist,
            nativeAccessibilityIdentifier: "detail.description"
        )
    }
}
