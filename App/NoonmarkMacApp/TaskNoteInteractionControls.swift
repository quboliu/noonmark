import AppKit
import NoonmarkCore
import SwiftUI

struct TaskNoteOverflowControl: NSViewRepresentable {
    let entryID: TaskNoteEntryID
    let copy: AppCopy
    let onEdit: () -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(copy: copy, onEdit: onEdit, onDelete: onDelete)
    }

    func makeNSView(context: Context) -> NSButton {
        context.coordinator.entryID = entryID
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: copy.noteActionsAccessibilityLabel
            ) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.showActions(_:))
        )
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.contentTintColor = .tertiaryLabelColor
        configureAccessibility(for: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onEdit = onEdit
        context.coordinator.onDelete = onDelete
        context.coordinator.entryID = entryID
        context.coordinator.copy = copy
        configureAccessibility(for: button)
    }

    private func configureAccessibility(for button: NSButton) {
        let identifier = "detail.note.actions.\(entryID.description)"
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: copy.noteActionsAccessibilityLabel
        ) ?? NSImage()
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.toolTip = copy.noteActionsAccessibilityLabel
        button.setAccessibilityLabel(copy.noteActionsAccessibilityLabel)
        button.setAccessibilityIdentifier(identifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var entryID: TaskNoteEntryID?
        var copy: AppCopy
        var onEdit: () -> Void
        var onDelete: () -> Void
        private weak var popover: NSPopover?

        init(copy: AppCopy, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
            self.copy = copy
            self.onEdit = onEdit
            self.onDelete = onDelete
        }

        @objc func showActions(_ sender: NSButton) {
            if let popover, popover.isShown {
                popover.performClose(nil)
                return
            }
            guard let entryID else { return }

            let popover = NSPopover()
            let controller = NSViewController()
            let menuView = TaskNoteActionMenuView(
                entryID: entryID,
                copy: copy,
                target: self,
                editAction: #selector(editNote(_:)),
                deleteAction: #selector(deleteNote(_:))
            )
            controller.view = menuView
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 148, height: 68)
            popover.behavior = .transient
            popover.animates = false
            self.popover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
            DispatchQueue.main.async {
                popover.contentViewController?.view.window?
                    .makeFirstResponder(menuView.initialFocusView)
                NSAccessibility.post(
                    element: menuView.initialFocusView,
                    notification: .focusedUIElementChanged
                )
            }
        }

        @objc private func editNote(_ sender: Any?) {
            popover?.performClose(nil)
            DispatchQueue.main.async { [onEdit] in onEdit() }
        }

        @objc private func deleteNote(_ sender: Any?) {
            popover?.performClose(nil)
            DispatchQueue.main.async { [onDelete] in onDelete() }
        }
    }
}

private final class TaskNoteActionMenuView: NSView {
    let initialFocusView: NSButton

    init(
        entryID: TaskNoteEntryID,
        copy: AppCopy,
        target: AnyObject,
        editAction: Selector,
        deleteAction: Selector
    ) {
        let editButton = Self.makeButton(
            title: copy.editNoteAction,
            symbol: "pencil",
            color: .labelColor,
            identifier: "detail.note.edit.\(entryID.description)"
        )
        initialFocusView = editButton
        super.init(frame: NSRect(x: 0, y: 0, width: 148, height: 68))

        editButton.target = target
        editButton.action = editAction
        editButton.frame = NSRect(x: 6, y: 35, width: 136, height: 27)
        addSubview(editButton)

        let deleteButton = Self.makeButton(
            title: copy.deleteNoteAction,
            symbol: "trash",
            color: .systemRed,
            identifier: "detail.note.delete.\(entryID.description)"
        )
        deleteButton.target = target
        deleteButton.action = deleteAction
        deleteButton.frame = NSRect(x: 6, y: 6, width: 136, height: 27)
        addSubview(deleteButton)
        setAccessibilityRole(.group)
        setAccessibilityLabel(copy.noteActionsAccessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private static func makeButton(
        title: String,
        symbol: String,
        color: NSColor,
        identifier: String
    ) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.alignment = .left
        button.font = .noonmarkSystemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = color
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: NoonmarkVisualMetrics.compactPointSize(12),
                    weight: .medium
                )
            )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        return button
    }
}

struct TaskNoteTextActionControl: NSViewRepresentable {
    enum Emphasis {
        case secondary
        case accent
    }

    let title: String
    let identifier: String
    let emphasis: Emphasis
    var isEnabled = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction(_:))
        )
        button.isBordered = false
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.title = title
        button.font = .noonmarkSystemFont(ofSize: 11, weight: emphasis == .accent ? .semibold : .medium)
        button.contentTintColor = emphasis == .accent ? .controlAccentColor : .tertiaryLabelColor
        button.isEnabled = isEnabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
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
