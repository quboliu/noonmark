import AppKit
import NoonmarkMacRuntime
import SwiftUI

enum DateNavigationKey: UInt16, CaseIterable {
    case left = 123
    case right = 124
    case down = 125
    case up = 126

    var direction: MoveCommandDirection {
        switch self {
        case .left: .left
        case .right: .right
        case .down: .down
        case .up: .up
        }
    }

    var characters: String {
        let functionKey = switch self {
        case .left: NSLeftArrowFunctionKey
        case .right: NSRightArrowFunctionKey
        case .down: NSDownArrowFunctionKey
        case .up: NSUpArrowFunctionKey
        }
        return String(UnicodeScalar(functionKey)!)
    }
}

struct DateNavigationKeyboardFocusBridge: NSViewRepresentable {
    let focusRequest: Int
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(focusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> DateNavigationKeyboardFocusView {
        let view = DateNavigationKeyboardFocusView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: DateNavigationKeyboardFocusView, context: Context) {
        configure(view)
        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        view.isFocusEnabled = true

        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    static func dismantleNSView(_ view: DateNavigationKeyboardFocusView, coordinator: Coordinator) {
        view.onMoveCommand = nil
        view.onFocusChange = nil
    }

    private func configure(_ view: DateNavigationKeyboardFocusView) {
        view.onMoveCommand = onMoveCommand
        view.onFocusChange = onFocusChange
    }

    final class Coordinator {
        var focusRequest: Int

        init(focusRequest: Int) {
            self.focusRequest = focusRequest
        }
    }
}

final class DateNavigationKeyboardFocusView: NSView {
    var onMoveCommand: ((MoveCommandDirection) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var isFocusEnabled = false

    override var acceptsFirstResponder: Bool { isFocusEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
            super.keyDown(with: event)
            return
        }

        guard let navigationKey = DateNavigationKey(rawValue: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        onMoveCommand?(navigationKey.direction)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct HorizontalPageNavigationBridge: NSViewRepresentable {
    let isEnabled: () -> Bool
    let onNavigate: (HorizontalPageNavigationDirection) -> Void

    func makeNSView(context: Context) -> HorizontalPageNavigationView {
        let view = HorizontalPageNavigationView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(
        _ view: HorizontalPageNavigationView,
        context: Context
    ) {
        configure(view)
    }

    static func dismantleNSView(
        _ view: HorizontalPageNavigationView,
        coordinator: ()
    ) {
        view.stopMonitoring()
        view.isEnabled = nil
        view.onNavigate = nil
    }

    private func configure(_ view: HorizontalPageNavigationView) {
        view.isEnabled = isEnabled
        view.onNavigate = onNavigate
    }
}

final class HorizontalPageNavigationView: NSView {
    var isEnabled: (() -> Bool)?
    var onNavigate: ((HorizontalPageNavigationDirection) -> Void)?

    private var recognizer = HorizontalPageNavigationRecognizer()
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    func stopMonitoring() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
        recognizer.reset()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func handle(_ event: NSEvent) {
        guard let window,
              event.windowNumber == window.windowNumber,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.firstResponder is NSTextView == false,
              isEnabled?() == true,
              event.modifierFlags.isDisjoint(
                  with: [.command, .control, .option]
              )
        else {
            recognizer.reset()
            return
        }

        let isMomentum = event.momentumPhase.isEmpty == false
        let isDirectionInverted = event.isDirectionInvertedFromDevice
        let sample = HorizontalPageNavigationSample(
            deltaX: HorizontalPageNavigationDeviceDelta.normalized(
                event.scrollingDeltaX,
                isDirectionInvertedFromDevice: isDirectionInverted
            ),
            deltaY: HorizontalPageNavigationDeviceDelta.normalized(
                event.scrollingDeltaY,
                isDirectionInvertedFromDevice: isDirectionInverted
            ),
            phase: Self.navigationPhase(
                for: isMomentum ? event.momentumPhase : event.phase
            ),
            isMomentum: isMomentum,
            isPrecise: event.hasPreciseScrollingDeltas
        )
        if let direction = recognizer.consume(sample) {
            onNavigate?(direction)
        }
    }

    private static func navigationPhase(
        for phase: NSEvent.Phase
    ) -> HorizontalPageNavigationPhase {
        if phase.contains(.cancelled) {
            return .cancelled
        }
        if phase.contains(.ended) {
            return .ended
        }
        if phase.contains(.began) {
            return .began
        }
        if phase.contains(.changed) {
            return .changed
        }
        if phase.contains(.mayBegin) {
            return .mayBegin
        }
        return .none
    }
}
