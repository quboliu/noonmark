import AppKit
import NoonmarkMacRuntime
import SwiftUI

/// Keeps an AppKit field editor in sole ownership of its active input draft.
///
/// Marked text and adjacent composition commits stay native until the input
/// reaches an idle boundary. Losing focus still flushes synchronously. This
/// prevents a parent view update from replacing the native field editor
/// between phrases from a third-party IME.
struct IMECompositionIsolatedTextField:
    NSViewRepresentable
{
    enum Surface {
        case plain
        case rounded
    }

    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let textColor: NSColor
    let nativeAccessibilityIdentifier: String
    var surface: Surface = .plain

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
        field.isEditable = true
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(
            "\(nativeAccessibilityIdentifier).input"
        )
        field.identifier = NSUserInterfaceItemIdentifier(
            "\(nativeAccessibilityIdentifier).input"
        )
        configureSurface(field)
        return field
    }

    func updateNSView(
        _ field: NSTextField,
        context: Context
    ) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
        configureSurface(field)
        guard case let .applyExternal(nextText) =
            context.coordinator.reconcileExternalText(text)
        else {
            return
        }
        guard let editor =
            field.currentEditor() as? NSTextView
        else {
            if field.stringValue != nextText {
                field.stringValue = nextText
            }
            return
        }
        guard editor.hasMarkedText() == false,
              editor.string != nextText
        else {
            return
        }
        let selection = editor.selectedRange()
        editor.string = nextText
        editor.setSelectedRange(
            NSRange(
                location: min(
                    selection.location,
                    nextText.utf16.count
                ),
                length: 0
            )
        )
    }

    static func dismantleNSView(
        _ field: NSTextField,
        coordinator: Coordinator
    ) {
        if let editor =
            field.currentEditor() as? NSTextView
        {
            if editor.hasMarkedText() {
                editor.unmarkText()
            }
            coordinator.captureNativeText(
                from: field
            )
        }
        coordinator.flushNativeText()
        coordinator.cancelPendingPublication()
        field.delegate = nil
    }

    private func configureSurface(
        _ field: NSTextField
    ) {
        switch surface {
        case .plain:
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
        case .rounded:
            field.isBezeled = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            field.drawsBackground = true
        }
    }

    @MainActor
    final class Coordinator:
        NSObject,
        NSTextFieldDelegate
    {
        var text: Binding<String>
        private var buffer: IMETextBindingBuffer
        private var pendingPublication:
            Task<Void, Never>?

        init(text: Binding<String>) {
            self.text = text
            buffer = IMETextBindingBuffer(
                initialText: text.wrappedValue
            )
        }

        func controlTextDidChange(
            _ notification: Notification
        ) {
            guard let field =
                notification.object as? NSTextField
            else {
                return
            }
            captureNativeText(from: field)
        }

        func controlTextDidEndEditing(
            _ notification: Notification
        ) {
            guard let field =
                notification.object as? NSTextField
            else {
                return
            }
            if let editor =
                field.currentEditor() as? NSTextView,
                editor.hasMarkedText()
            {
                editor.unmarkText()
            }
            captureNativeText(from: field)
            flushNativeText()
        }

        func reconcileExternalText(
            _ nextText: String
        ) -> IMETextBindingBuffer.ExternalTextDecision {
            let decision =
                buffer.reconcileExternalText(nextText)
            if buffer.isComposing == false,
               buffer.hasUnpublishedText == false
            {
                cancelPendingPublication()
            }
            return decision
        }

        func captureNativeText(
            from field: NSTextField
        ) {
            let editor =
                field.currentEditor() as? NSTextView
            let nextText =
                editor?.string ?? field.stringValue
            let isComposing =
                editor?.hasMarkedText() == true
            switch buffer.nativeSnapshotDidChange(
                text: nextText,
                isComposing: isComposing
            ) {
            case .unchanged:
                break
            case .cancel:
                cancelPendingPublication()
            case let .schedule(schedule):
                replacePendingPublication(
                    with: schedule
                )
            }
        }

        func flushNativeText() {
            cancelPendingPublication()
            guard let nextText =
                buffer.takeImmediatePublication()
            else {
                return
            }
            publish(nextText)
        }

        func cancelPendingPublication() {
            pendingPublication?.cancel()
            pendingPublication = nil
        }

        private func replacePendingPublication(
            with schedule:
                IMETextBindingBuffer.PublicationSchedule
        ) {
            cancelPendingPublication()
            pendingPublication =
                Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            for: .milliseconds(
                                schedule
                                    .delayMilliseconds
                            )
                        )
                    } catch {
                        return
                    }
                    guard let self,
                          Task.isCancelled == false,
                          let nextText =
                          buffer.takePublication(
                              for: schedule
                          )
                    else {
                        return
                    }
                    pendingPublication = nil
                    publish(nextText)
                }
        }

        private func publish(_ nextText: String) {
            guard text.wrappedValue != nextText else {
                return
            }
            text.wrappedValue = nextText
        }
    }
}
