import Combine
import Foundation

public enum GlobalShortcutKey: String, Codable, CaseIterable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case space

    private static let keyByCharacter: [String: Self] = [
        "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f,
        "g": .g, "h": .h, "i": .i, "j": .j, "k": .k, "l": .l,
        "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r,
        "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x,
        "y": .y, "z": .z,
        "0": .zero, "1": .one, "2": .two, "3": .three,
        "4": .four, "5": .five, "6": .six, "7": .seven,
        "8": .eight, "9": .nine,
        " ": .space
    ]

    public init?(virtualKeyCode: UInt16) {
        guard let key = Self.allCases.first(where: {
            $0.virtualKeyCode == virtualKeyCode
        }) else {
            return nil
        }
        self = key
    }

    public init?(charactersIgnoringModifiers: String) {
        guard let key = Self.keyByCharacter[
            charactersIgnoringModifiers.lowercased()
        ] else {
            return nil
        }
        self = key
    }

    public var virtualKeyCode: UInt16 {
        switch self {
        case .a: 0
        case .s: 1
        case .d: 2
        case .f: 3
        case .h: 4
        case .g: 5
        case .z: 6
        case .x: 7
        case .c: 8
        case .v: 9
        case .b: 11
        case .q: 12
        case .w: 13
        case .e: 14
        case .r: 15
        case .y: 16
        case .t: 17
        case .one: 18
        case .two: 19
        case .three: 20
        case .four: 21
        case .six: 22
        case .five: 23
        case .nine: 25
        case .seven: 26
        case .eight: 28
        case .zero: 29
        case .o: 31
        case .u: 32
        case .i: 34
        case .p: 35
        case .l: 37
        case .j: 38
        case .k: 40
        case .n: 45
        case .m: 46
        case .space: 49
        }
    }

    public var displayText: String {
        switch self {
        case .space:
            "Space"
        case .zero:
            "0"
        case .one:
            "1"
        case .two:
            "2"
        case .three:
            "3"
        case .four:
            "4"
        case .five:
            "5"
        case .six:
            "6"
        case .seven:
            "7"
        case .eight:
            "8"
        case .nine:
            "9"
        default:
            rawValue.uppercased()
        }
    }
}

public struct GlobalShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)

    public var count: Int {
        rawValue.nonzeroBitCount
    }
}

public struct GlobalQuickEntryShortcut: Codable, Equatable, Hashable, Sendable {
    public let key: GlobalShortcutKey
    public let modifiers: GlobalShortcutModifiers

    public init(
        key: GlobalShortcutKey,
        modifiers: GlobalShortcutModifiers
    ) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let standard = Self(
        key: .n,
        modifiers: [.control, .shift]
    )

    public var displayText: String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        return result + key.displayText
    }
}

public struct GlobalQuickEntryShortcutPreference: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let shortcut: GlobalQuickEntryShortcut

    public init(
        isEnabled: Bool,
        shortcut: GlobalQuickEntryShortcut
    ) {
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }

    public static let standard = Self(
        isEnabled: true,
        shortcut: .standard
    )
}

@MainActor
public protocol GlobalShortcutPreferenceStoring: AnyObject {
    func load() -> GlobalQuickEntryShortcutPreference
    func save(_ preference: GlobalQuickEntryShortcutPreference)
}

@MainActor
public final class GlobalShortcutPreferenceRepository: GlobalShortcutPreferenceStoring {
    public static let defaultStorageKey =
        "Noonmark.GlobalQuickEntryShortcut.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> GlobalQuickEntryShortcutPreference {
        guard let storedValue = defaults.object(forKey: storageKey) else {
            return .standard
        }
        guard let data = storedValue as? Data,
              let preference = try? decoder.decode(
                  GlobalQuickEntryShortcutPreference.self,
                  from: data
              )
        else {
            return GlobalQuickEntryShortcutPreference(
                isEnabled: false,
                shortcut: .standard
            )
        }
        return preference
    }

    public func save(_ preference: GlobalQuickEntryShortcutPreference) {
        guard let data = try? encoder.encode(preference) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

public enum GlobalQuickEntryShortcutValidation: Equatable, Sendable {
    case allowed
    case unsafeModifierCombination
    case noonmarkCommandConflict
    case systemShortcutConflict
    case conflictInspectionUnavailable
}

public enum GlobalShortcutSnapshot: Equatable, Sendable {
    case available(Set<GlobalQuickEntryShortcut>)
    case unavailable
}

public struct GlobalQuickEntryShortcutPolicy: Sendable {
    public init() {}

    public func validate(
        _ shortcut: GlobalQuickEntryShortcut,
        noonmarkShortcutSnapshot: GlobalShortcutSnapshot,
        systemShortcutSnapshot: GlobalShortcutSnapshot
    ) -> GlobalQuickEntryShortcutValidation {
        guard shortcut.modifiers.count >= 2,
              shortcut.modifiers.contains(.command)
              || shortcut.modifiers.contains(.control)
        else {
            return .unsafeModifierCombination
        }
        guard case let .available(noonmarkReservedShortcuts) =
            noonmarkShortcutSnapshot
        else {
            return .conflictInspectionUnavailable
        }
        guard noonmarkReservedShortcuts.contains(shortcut) == false else {
            return .noonmarkCommandConflict
        }
        guard case let .available(enabledSystemShortcuts) =
            systemShortcutSnapshot
        else {
            return .conflictInspectionUnavailable
        }
        guard enabledSystemShortcuts.contains(shortcut) == false else {
            return .systemShortcutConflict
        }
        return .allowed
    }
}

/// A conforming registrar must leave its existing binding untouched when
/// `register` returns `false`.
@MainActor
public protocol GlobalQuickEntryShortcutRegistering: AnyObject {
    func register(
        _ shortcut: GlobalQuickEntryShortcut,
        onTrigger: @escaping @MainActor () -> Void
    ) -> Bool

    func unregister()
}

public enum GlobalShortcutRegistrationStatus: Equatable, Sendable {
    case disabled
    case active
    case validationFailed(
        reason: GlobalQuickEntryShortcutValidation,
        retainedShortcut: GlobalQuickEntryShortcut?
    )
    case registrationFailed(retainedShortcut: GlobalQuickEntryShortcut?)
}

@MainActor
public final class GlobalQuickEntryShortcutCoordinator: ObservableObject {
    @Published public private(set) var preference:
        GlobalQuickEntryShortcutPreference
    @Published public private(set) var status:
        GlobalShortcutRegistrationStatus = .disabled

    private let repository: any GlobalShortcutPreferenceStoring
    private let registrar: any GlobalQuickEntryShortcutRegistering
    private let policy: GlobalQuickEntryShortcutPolicy
    private let noonmarkShortcutSnapshot:
        @MainActor () -> GlobalShortcutSnapshot
    private let systemShortcutSnapshot:
        @MainActor () -> GlobalShortcutSnapshot
    private let onTrigger: @MainActor () -> Void
    private var registeredShortcut: GlobalQuickEntryShortcut?
    private var hasStarted = false

    public init(
        repository: any GlobalShortcutPreferenceStoring,
        registrar: any GlobalQuickEntryShortcutRegistering,
        policy: GlobalQuickEntryShortcutPolicy = .init(),
        noonmarkShortcutSnapshot: @escaping @MainActor ()
            -> GlobalShortcutSnapshot,
        systemShortcutSnapshot: @escaping @MainActor ()
            -> GlobalShortcutSnapshot,
        onTrigger: @escaping @MainActor () -> Void
    ) {
        self.repository = repository
        self.registrar = registrar
        self.policy = policy
        self.noonmarkShortcutSnapshot = noonmarkShortcutSnapshot
        self.systemShortcutSnapshot = systemShortcutSnapshot
        self.onTrigger = onTrigger
        preference = repository.load()
    }

    public func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        activate(preference, shouldPersist: false)
    }

    public func apply(_ candidate: GlobalQuickEntryShortcutPreference) {
        activate(candidate, shouldPersist: true)
    }

    public func stop() {
        registrar.unregister()
        registeredShortcut = nil
        hasStarted = false
        status = .disabled
    }

    private func activate(
        _ candidate: GlobalQuickEntryShortcutPreference,
        shouldPersist: Bool
    ) {
        guard candidate.isEnabled else {
            registrar.unregister()
            registeredShortcut = nil
            preference = candidate
            if shouldPersist {
                repository.save(candidate)
            }
            status = .disabled
            return
        }

        let validation = policy.validate(
            candidate.shortcut,
            noonmarkShortcutSnapshot: noonmarkShortcutSnapshot(),
            systemShortcutSnapshot: systemShortcutSnapshot()
        )
        guard validation == .allowed else {
            status = .validationFailed(
                reason: validation,
                retainedShortcut: registeredShortcut
            )
            return
        }

        if registeredShortcut == candidate.shortcut {
            preference = candidate
            if shouldPersist {
                repository.save(candidate)
            }
            status = .active
            return
        }

        guard registrar.register(
            candidate.shortcut,
            onTrigger: onTrigger
        ) else {
            status = .registrationFailed(
                retainedShortcut: registeredShortcut
            )
            return
        }

        registeredShortcut = candidate.shortcut
        preference = candidate
        if shouldPersist {
            repository.save(candidate)
        }
        status = .active
    }
}
