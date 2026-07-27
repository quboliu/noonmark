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

struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text3)
            content
        }
    }
}

struct SegmentedPair: View {
    let left: String
    let right: String
    let leftSelected: Bool
    let leftAction: () -> Void
    let rightAction: () -> Void
    let identifier: String

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { leftSelected },
                set: { $0 ? leftAction() : rightAction() }
            )
        ) {
            Text(left).tag(true)
            Text(right).tag(false)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .accessibilityIdentifier(identifier)
    }
}

struct SegmentedOptionRow<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let action: (Option) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { selected },
                set: { action($0) }
            )
        ) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }
}

struct PageHeader<Trailing: View>: View {
    @EnvironmentObject private var store: NoonmarkStore
    let title: String
    let subtitle: String?
    let badge: String?
    let badgeColor: Color
    let titlePlacement: MacUIPageHeaderTitlePlacement
    let centerSubtitleWithTitle: Bool
    let titleAnchorIdentifier: String?
    let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        badgeColor: Color = Theme.accent,
        titlePlacement: MacUIPageHeaderTitlePlacement = MacUIPageHeaderLayout.defaultTitlePlacement,
        centerSubtitleWithTitle: Bool = false,
        titleAnchorIdentifier: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.badgeColor = badgeColor
        self.titlePlacement = titlePlacement
        self.centerSubtitleWithTitle = centerSubtitleWithTitle
        self.titleAnchorIdentifier = titleAnchorIdentifier
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if titlePlacement == .centeredInMainSurface {
                        titleLabel(exposesE2EAnchor: false)
                            .hidden()
                            .accessibilityHidden(true)
                    } else {
                        titleLabel(exposesE2EAnchor: true)
                    }
                    if let badge {
                        StatusPill(text: badge, color: badgeColor)
                    }
                }
                if let subtitle {
                    if centerSubtitleWithTitle, titlePlacement == .centeredInMainSurface {
                        subtitleLabel(subtitle)
                            .hidden()
                            .accessibilityHidden(true)
                    } else {
                        subtitleLabel(subtitle)
                    }
                }
            }
            Spacer()
            trailing
            if store.hasDetailRailContent && store.isDetailRailExpanded == false {
                PaneBoundaryToggle(
                    direction: .left,
                    accessibilityLabel: store.copy.expandDetailRail,
                    identifier: "shell.detail-rail.toggle"
                ) {
                    store.toggleDetailRail()
                }
            }
        }
        .overlay(alignment: .top) {
            if titlePlacement == .centeredInMainSurface {
                VStack(spacing: 2) {
                    titleLabel(exposesE2EAnchor: true)
                    if centerSubtitleWithTitle, let subtitle {
                        subtitleLabel(subtitle)
                            .multilineTextAlignment(.center)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.vertical, 14)
    }

    private func titleLabel(exposesE2EAnchor: Bool) -> some View {
        Text(title)
            .font(.noonmarkSystem(size: 21, weight: .bold))
            .background {
                if exposesE2EAnchor, let titleAnchorIdentifier {
                    AppE2EViewAnchor(
                        identifier: titleAnchorIdentifier,
                        verificationText: title
                    )
                }
            }
    }

    private func subtitleLabel(_ subtitle: String) -> some View {
        Text(subtitle)
            .font(.noonmarkSystem(size: 12))
            .foregroundStyle(Theme.text3)
    }
}

enum PaneBoundaryDirection {
    case left
    case right
}

struct PaneBoundaryToggle: View {
    let direction: PaneBoundaryDirection
    let accessibilityLabel: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: -1.5) {
                chevron
                chevron
            }
            .frame(width: 17, height: 15)
            .frame(
                width: NoonmarkVisualMetrics.paneToggleButtonSize,
                height: NoonmarkVisualMetrics.paneToggleButtonSize
            )
            .contentShape(Rectangle())
            .foregroundStyle(Theme.text3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .help(accessibilityLabel)
        .hoverSurface(
            cornerRadius: 6,
            idleFill: .clear,
            hoverFill: Theme.listRowHover,
            idleStroke: .clear,
            hoverStroke: Theme.line.opacity(0.5)
        )
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: accessibilityLabel
            )
        }
    }

    private var chevron: some View {
        Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
            .font(
                .noonmarkRenderedSystem(
                    size: NoonmarkVisualMetrics.paneToggleChevronSize,
                    weight: .semibold
                )
            )
    }
}

struct HeaderButton: View {
    let title: String
    let accessibilityLabel: String?
    let action: () -> Void

    init(
        _ title: String,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, title.count == 1 ? 8 : 10)
                .frame(
                    minWidth: CGFloat(
                        MacUIAccessibilityLayout.minimumInteractiveTargetSize
                    ),
                    minHeight: CGFloat(
                        MacUIAccessibilityLayout.minimumInteractiveTargetSize
                    )
                )
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .accessibilityLabel(accessibilityLabel ?? title)
            .help(accessibilityLabel ?? title)
            .hoverSurface(
                cornerRadius: 7,
                idleFill: Theme.controlFill,
                hoverFill: Theme.listRowHover,
                idleStroke: Theme.line.opacity(0.72),
                hoverStroke: Theme.line2.opacity(0.72)
            )
    }
}

struct SmallActionButton: View {
    enum Tone { case normal, accent, warn }
    let title: String
    let tone: Tone
    let action: () -> Void

    init(_ title: String, tone: Tone = .normal, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    var color: Color {
        switch tone {
        case .normal: Theme.text2
        case .accent: Theme.accent
        case .warn: Theme.warn
        }
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.noonmarkSystem(size: 11.5))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(
                minHeight: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
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

/// A single native control for compact settings actions that require a stable
/// AppKit accessibility identity. Its SwiftUI surface supplies the visual
/// treatment; this button remains the only hit-test and accessibility target.
struct NativeSmallActionButton: NSViewRepresentable {
    let title: String
    let tone: SmallActionButton.Tone
    let identifier: String
    let accessibilityLabel: String
    var isEnabled = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NativeSmallActionButtonView {
        let button = NativeSmallActionButtonView(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        configure(button)
        return button
    }

    func updateNSView(_ button: NativeSmallActionButtonView, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NativeSmallActionButtonView) {
        button.title = title
        button.font = .noonmarkSystemFont(ofSize: 11.5)
        button.contentTintColor = NSColor(color)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.toolTip = accessibilityLabel
        button.isEnabled = isEnabled
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.invalidateIntrinsicContentSize()
    }

    private var color: Color {
        switch tone {
        case .normal: Theme.text2
        case .accent: Theme.accent
        case .warn: Theme.warn
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: Any?) {
            action()
        }
    }
}

final class NativeSmallActionButtonView: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        setButtonType(.momentaryPushIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let titleSize = title.size(withAttributes: [
            .font: font ?? .noonmarkSystemFont(ofSize: 11.5),
        ])
        return NSSize(
            width: ceil(titleSize.width) + 18,
            height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
        )
    }
}

/// A native switch whose visible hit target and accessibility identity are the
/// same AppKit control. Settings uses this for stateful controls that must be
/// equally reliable for keyboard, VoiceOver, and real-App automation.
struct NativeSettingsSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    let identifier: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.target = context.coordinator
        control.action = #selector(Coordinator.performAction(_:))
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        configure(control)
    }

    private func configure(_ control: NSSwitch) {
        let targetState: NSControl.StateValue = isOn ? .on : .off
        if control.state != targetState {
            control.state = targetState
        }
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.toolTip = accessibilityLabel
        control.setAccessibilityIdentifier(identifier)
        control.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func performAction(_ sender: Any?) {
            guard let control = sender as? NSSwitch else { return }
            isOn.wrappedValue = control.state == .on
        }
    }
}

/// A native single-line field for settings whose identifier must belong to the
/// actual editable AppKit control, rather than a SwiftUI hosting wrapper.
struct NativeSettingsTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let accessibilityLabel: String

    func makeCoordinator() -> NativeSettingsTextFieldCoordinator {
        NativeSettingsTextFieldCoordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        configure(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        configure(field)
    }

    private func configure(_ field: NSTextField) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.font = .noonmarkSystemFont(ofSize: 12.5)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.toolTip = accessibilityLabel
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(accessibilityLabel)
    }
}

/// The secure counterpart of `NativeSettingsTextField`. Its value is kept in
/// memory only until the caller saves it, while the AppKit field itself keeps a
/// stable accessibility identity for a normal, masked credential entry flow.
struct NativeSettingsSecureField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let accessibilityLabel: String

    func makeCoordinator() -> NativeSettingsTextFieldCoordinator {
        NativeSettingsTextFieldCoordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.delegate = context.coordinator
        configure(field)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        configure(field)
    }

    private func configure(_ field: NSSecureTextField) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.font = .noonmarkSystemFont(ofSize: 12.5)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.toolTip = accessibilityLabel
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(accessibilityLabel)
    }
}

final class NativeSettingsTextFieldCoordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
        self.text = text
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let nextText = field.stringValue
        guard text.wrappedValue != nextText else { return }
        text.wrappedValue = nextText
    }
}

struct HoverSurfaceModifier: ViewModifier {
    @State private var hovering = false

    let active: Bool
    let cornerRadius: CGFloat
    let idleFill: Color
    let hoverFill: Color
    let activeFill: Color
    let idleStroke: Color
    let hoverStroke: Color
    let activeStroke: Color
    let activeLineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(active ? activeFill : hovering ? hoverFill : idleFill)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(active ? activeStroke : hovering ? hoverStroke : idleStroke, lineWidth: active ? activeLineWidth : 1)
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
    }
}

struct ListRowSurfaceModifier: ViewModifier {
    let selected: Bool
    let tint: Color
    let cornerRadius: CGFloat
    let separatorLeadingInset: CGFloat

    func body(content: Content) -> some View {
        content
            .hoverSurface(
                active: selected,
                cornerRadius: cornerRadius,
                idleFill: Theme.panel,
                hoverFill: Theme.listRowHover,
                activeFill: tint.opacity(0.08),
                idleStroke: .clear,
                hoverStroke: .clear,
                activeStroke: .clear
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.line.opacity(selected ? 0 : 0.62))
                    .frame(height: 1)
                    .padding(.leading, separatorLeadingInset)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? tint.opacity(0.22) : .clear, lineWidth: 1)
            }
    }
}

extension View {
    func hoverSurface(
        active: Bool = false,
        cornerRadius: CGFloat,
        idleFill: Color,
        hoverFill: Color,
        activeFill: Color? = nil,
        idleStroke: Color,
        hoverStroke: Color,
        activeStroke: Color? = nil,
        activeLineWidth: CGFloat = 1
    ) -> some View {
        modifier(
            HoverSurfaceModifier(
                active: active,
                cornerRadius: cornerRadius,
                idleFill: idleFill,
                hoverFill: hoverFill,
                activeFill: activeFill ?? hoverFill,
                idleStroke: idleStroke,
                hoverStroke: hoverStroke,
                activeStroke: activeStroke ?? hoverStroke,
                activeLineWidth: activeLineWidth
            )
        )
    }

    func listRowSurface(
        selected: Bool,
        tint: Color,
        cornerRadius: CGFloat = 7,
        separatorLeadingInset: CGFloat = 0
    ) -> some View {
        modifier(
            ListRowSurfaceModifier(
                selected: selected,
                tint: tint,
                cornerRadius: cornerRadius,
                separatorLeadingInset: separatorLeadingInset
            )
        )
    }
}

struct PriorityStepper: View {
    @EnvironmentObject private var store: NoonmarkStore
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    private let segmentSize = CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)

    var body: some View {
        HStack(spacing: 0) {
            PriorityStepButton(
                systemName: "arrow.up",
                enabled: canMoveUp,
                accessibilityLabel: store.copy.movePriorityUp,
                action: moveUp
            )
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1, height: 12)
            PriorityStepButton(
                systemName: "arrow.down",
                enabled: canMoveDown,
                accessibilityLabel: store.copy.movePriorityDown,
                action: moveDown
            )
        }
        .frame(height: segmentSize)
        .background(Theme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.line)
        )
        .help(store.copy.adjustDayPriority)
    }
}

private struct PriorityStepButton: View {
    let systemName: String
    let enabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.noonmarkSystem(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text2 : Theme.line2)
                .frame(
                    width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                    height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                )
                .background(isHovered && enabled ? Theme.chip : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = enabled && $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct StatusDot: View {
    let status: TraceStatus
    var size: CGFloat = 4

    var body: some View {
        Circle()
            .fill(status.uiStyle.dotColor)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TraceStatusStyle {
    let glyph: String
    let foreground: Color
    let softBackground: Color
    let glyphForeground: Color
    let glyphBackground: Color
    let glyphBorder: Color
    let dotColor: Color
    let titleColor: Color
    let strikethrough: Bool
}

extension TraceStatus {
    var uiStyle: TraceStatusStyle {
        switch self {
        case .pending:
            TraceStatusStyle(
                glyph: "",
                foreground: Theme.accent,
                softBackground: Theme.accentSoft,
                glyphForeground: Theme.accent,
                glyphBackground: Theme.panel,
                glyphBorder: Theme.line2,
                dotColor: Theme.accent,
                titleColor: Theme.text1,
                strikethrough: false
            )
        case .completed:
            TraceStatusStyle(
                glyph: "✓",
                foreground: Theme.ok,
                softBackground: Theme.okSoft,
                glyphForeground: .white,
                glyphBackground: Theme.ok,
                glyphBorder: .clear,
                dotColor: Theme.ok,
                titleColor: Theme.text3,
                strikethrough: true
            )
        case .unfinished:
            TraceStatusStyle(
                glyph: "✕",
                foreground: Theme.warn,
                softBackground: Theme.warnSoft,
                glyphForeground: Theme.warn,
                glyphBackground: Theme.warnSoft,
                glyphBorder: .clear,
                dotColor: Theme.warn,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .deferred:
            TraceStatusStyle(
                glyph: "→",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .changed:
            TraceStatusStyle(
                glyph: "⇄",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .returnedToPool:
            TraceStatusStyle(
                glyph: "↩",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .cancelledDraft:
            preconditionFailure("Internal trace status has no UI style")
        case .abandoned:
            TraceStatusStyle(
                glyph: "—",
                foreground: Theme.text3,
                softBackground: Theme.chip,
                glyphForeground: Theme.text3,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text3,
                strikethrough: true
            )
        }
    }
}

struct StatusGlyph: View {
    enum Scale { case standard, compact }

    let status: TraceStatus
    let scale: Scale
    var style: TraceStatusStyle { status.uiStyle }

    init(status: TraceStatus, scale: Scale = .standard) {
        self.status = status
        self.scale = scale
    }

    var body: some View {
        Text(style.glyph)
            .font(.noonmarkSystem(size: scale == .compact ? 10 : 11, weight: .bold))
            .foregroundStyle(style.glyphForeground)
            .frame(width: scale == .compact ? 16 : 18, height: scale == .compact ? 16 : 18)
            .background(Circle().fill(style.glyphBackground))
            .overlay(Circle().stroke(style.glyphBorder, lineWidth: 1.5))
    }
}

struct StatusChip: View {
    @EnvironmentObject private var store: NoonmarkStore
    enum Scale { case standard, compact }

    let status: TraceStatus
    let scale: Scale
    var style: TraceStatusStyle { status.uiStyle }

    init(status: TraceStatus, scale: Scale = .standard) {
        self.status = status
        self.scale = scale
    }

    var body: some View {
        HStack(spacing: scale == .compact ? 4 : 5) {
            StatusDot(
                status: status,
                size: scale == .compact ? 4 : 5
            )
            Text(store.copy.traceStatusLabel(status))
        }
        .font(.noonmarkSystem(size: scale == .compact ? 10.5 : 11, weight: .medium))
        .foregroundStyle(style.foreground)
        .padding(.leading, scale == .compact ? 6 : 8)
        .padding(.trailing, scale == .compact ? 7 : 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(style.softBackground))
    }
}

struct Notice: View {
    enum Tone { case locked, future }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tone == .locked ? "lock.fill" : "calendar.badge.clock")
            Text(text)
        }
        .font(.noonmarkSystem(size: 12))
        .foregroundStyle(tone == .locked ? Theme.text2 : Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone == .locked ? Theme.chip : Theme.accentSoft))
    }
}

enum EmptyStateKind {
    case dayTodo
    case taskPool
    case futurePlans
    case recurringPlans
    case unfinishedPool
    case completedPool
    case calendar
}

struct EmptyState: View {
    let kind: EmptyStateKind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        kind: EmptyStateKind,
        text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.noonmarkSystem(size: 24, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.noonmarkSystem(size: 12.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private extension EmptyStateKind {
    var systemImage: String {
        switch self {
        case .dayTodo: "sun.max"
        case .taskPool: "tray"
        case .futurePlans: "calendar.badge.clock"
        case .recurringPlans: "repeat"
        case .unfinishedPool: "arrow.uturn.forward.circle"
        case .completedPool: "checkmark.seal"
        case .calendar: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .dayTodo: Theme.navDay
        case .taskPool: Theme.navPool
        case .futurePlans: Theme.navFuture
        case .recurringPlans: Theme.navRecurring
        case .unfinishedPool: Theme.navUnfinished
        case .completedPool: Theme.navCompleted
        case .calendar: Theme.navCalendar
        }
    }
}

struct TaskLifecycleSummaryLine<Content: View>: View {
    let accessibilityIdentifier: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .font(.noonmarkSystem(size: 11))
        .foregroundStyle(Theme.text2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: "plain"
            )
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let showsTitle: Bool
    @ViewBuilder let content: Content

    init(
        _ title: String,
        showsTitle: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsTitle = showsTitle
        self.content = content()
    }

    var body: some View {
        if showsTitle {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                content
            }
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
        }
    }
}

struct TaskClassificationDetailSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let trace: DayTrace
    let taskTitle: String

    var body: some View {
        DetailSection(store.copy.classificationAndLabelsTitle, showsTitle: false) {
            TaskClassificationEditor(
                chainID: trace.chainID,
                taskTitle: taskTitle
            )
        }
    }
}
