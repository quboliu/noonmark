import Carbon.HIToolbox
import Foundation
import NoonmarkMacRuntime

@MainActor
final class CarbonGlobalQuickEntryShortcutRegistrar: GlobalQuickEntryShortcutRegistering {
    /// Distinct signature per registrar instance: every hotkey event reaches
    /// every installed handler, so each registrar must only answer its own
    /// signature. The idea-capture registrar passes its own value.
    static let quickEntrySignature: UInt32 = 0x4E4D_5145
    static let ideaCaptureSignature: UInt32 = 0x4E4D_4945

    private let signature: UInt32
    private var eventHandler: EventHandlerRef?
    private var currentHotKey: EventHotKeyRef?
    private var currentShortcut: GlobalQuickEntryShortcut?
    private var currentIdentifier: UInt32 = 0
    private var nextIdentifier: UInt32 = 1
    private var onTrigger: (@MainActor () -> Void)?

    init(signature: UInt32 = quickEntrySignature) {
        self.signature = signature
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let registrar = Unmanaged<
                    CarbonGlobalQuickEntryShortcutRegistrar
                >
                .fromOpaque(userData)
                .takeUnretainedValue()
                return MainActor.assumeIsolated {
                    registrar.handle(event)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            eventHandler = nil
        }
    }

    func register(
        _ shortcut: GlobalQuickEntryShortcut,
        onTrigger: @escaping @MainActor () -> Void
    ) -> Bool {
        guard eventHandler != nil else { return false }
        if currentShortcut == shortcut {
            self.onTrigger = onTrigger
            return true
        }

        let identifier = nextIdentifier
        nextIdentifier &+= 1
        var candidateReference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.key.virtualKeyCode),
            carbonModifiers(for: shortcut.modifiers),
            EventHotKeyID(
                signature: signature,
                id: identifier
            ),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &candidateReference
        )
        guard status == noErr, let candidateReference else {
            return false
        }

        if let currentHotKey {
            UnregisterEventHotKey(currentHotKey)
        }
        currentHotKey = candidateReference
        currentShortcut = shortcut
        currentIdentifier = identifier
        self.onTrigger = onTrigger
        return true
    }

    func unregister() {
        if let currentHotKey {
            UnregisterEventHotKey(currentHotKey)
        }
        currentHotKey = nil
        currentShortcut = nil
        currentIdentifier = 0
        onTrigger = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == signature,
              identifier.id == currentIdentifier
        else {
            return OSStatus(eventNotHandledErr)
        }
        onTrigger?()
        return noErr
    }

    private func carbonModifiers(
        for modifiers: GlobalShortcutModifiers
    ) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        return result
    }
}

enum CarbonSystemShortcutInspector {
    @MainActor
    static func snapshot() -> GlobalShortcutSnapshot {
        var unmanagedArray: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedArray) == noErr,
              let array = unmanagedArray?.takeRetainedValue()
        else {
            return .unavailable
        }

        var result: Set<GlobalQuickEntryShortcut> = []
        for case let dictionary as NSDictionary in array as NSArray {
            guard let enabled = dictionary[
                "kHISymbolicHotKeyEnabled"
            ] as? Bool,
                enabled,
                let keyCodeNumber = dictionary[
                    "kHISymbolicHotKeyCode"
                ] as? NSNumber,
                let modifiersNumber = dictionary[
                    "kHISymbolicHotKeyModifiers"
                ] as? NSNumber,
                let key = GlobalShortcutKey(
                    virtualKeyCode: keyCodeNumber.uint16Value
                )
            else {
                continue
            }
            result.insert(
                GlobalQuickEntryShortcut(
                    key: key,
                    modifiers: modifiers(
                        fromCarbonValue: modifiersNumber.uint32Value
                    )
                )
            )
        }
        return .available(result)
    }

    private static func modifiers(
        fromCarbonValue value: UInt32
    ) -> GlobalShortcutModifiers {
        var result: GlobalShortcutModifiers = []
        if value & UInt32(cmdKey) != 0 {
            result.insert(.command)
        }
        if value & UInt32(controlKey) != 0 {
            result.insert(.control)
        }
        if value & UInt32(optionKey) != 0 {
            result.insert(.option)
        }
        if value & UInt32(shiftKey) != 0 {
            result.insert(.shift)
        }
        return result
    }
}

enum CarbonKeyboardLayoutResolver {
    @MainActor
    static func physicalKeyByCharacter() -> [String: GlobalShortcutKey]? {
        let inputSource = TISCopyCurrentKeyboardLayoutInputSource()
            .takeRetainedValue()
        guard let property = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let data = Unmanaged<CFData>
            .fromOpaque(property)
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var result: [String: GlobalShortcutKey] = [:]
        for key in GlobalShortcutKey.allCases {
            guard let character = translatedCharacter(
                for: key,
                layout: layout
            ) else {
                return nil
            }
            let normalizedCharacter = character.lowercased()
            guard result[normalizedCharacter] == nil else {
                return nil
            }
            result[normalizedCharacter] = key
        }
        return result
    }

    private static func translatedCharacter(
        for key: GlobalShortcutKey,
        layout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var outputLength = 0
        var output = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            key.virtualKeyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            output.count,
            &outputLength,
            &output
        )
        guard status == noErr, outputLength > 0 else { return nil }
        return String(
            utf16CodeUnits: output,
            count: outputLength
        )
    }
}
