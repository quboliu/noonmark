import AppKit
import Foundation
import NoonmarkDayContext
import NoonmarkMacRuntime

@MainActor
final class SystemNaturalDayEnvironment: NaturalDayEnvironment {
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var midnightTimer: Timer?
    private var signalHandler: (@MainActor @Sendable (NaturalDaySignal) -> Void)?

    func sample() throws -> NaturalDayEnvironmentSample {
        NaturalDayEnvironmentSample(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            localeIdentifier: Locale.autoupdatingCurrent.identifier
        )
    }

    func start(
        _ handler: @escaping @MainActor @Sendable (NaturalDaySignal) -> Void
    ) -> NaturalDayObservation {
        stop()
        signalHandler = handler

        observe(
            NotificationCenter.default,
            name: .NSCalendarDayChanged,
            signal: .calendarDayChanged
        )
        observe(
            NotificationCenter.default,
            name: .NSSystemClockDidChange,
            signal: .systemClockChanged
        )
        observe(
            NotificationCenter.default,
            name: .NSSystemTimeZoneDidChange,
            signal: .timeZoneChanged
        )
        observe(
            NotificationCenter.default,
            name: NSLocale.currentLocaleDidChangeNotification,
            signal: .localeChanged
        )
        observe(
            NotificationCenter.default,
            name: NSApplication.didBecomeActiveNotification,
            signal: .applicationBecameActive
        )
        observe(
            NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didWakeNotification,
            signal: .wake
        )
        scheduleMidnightTimer()

        return NaturalDayObservation { [weak self] in
            self?.stop()
        }
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        signal: NaturalDaySignal
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(signal)
            }
        }
        notificationTokens.append((center, token))
    }

    private func send(_ signal: NaturalDaySignal) {
        signalHandler?(signal)
        scheduleMidnightTimer()
    }

    private func scheduleMidnightTimer() {
        midnightTimer?.invalidate()

        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone.autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .day, for: now) else {
            return
        }

        let delay = interval.end.timeIntervalSince(now)
        guard delay.isFinite, delay > 0 else {
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.midnight)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func stop() {
        midnightTimer?.invalidate()
        midnightTimer = nil
        for (center, token) in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
        signalHandler = nil
    }
}

@MainActor
final class FixedNaturalDayEnvironment: NaturalDayEnvironment {
    private var fixedSample: NaturalDayEnvironmentSample
    private var signalHandler: (@MainActor @Sendable (NaturalDaySignal) -> Void)?

    init(
        instant: Date,
        timeZoneIdentifier: String,
        localeIdentifier: String
    ) {
        fixedSample = NaturalDayEnvironmentSample(
            instant: instant,
            timeZoneIdentifier: timeZoneIdentifier,
            localeIdentifier: localeIdentifier
        )
    }

    func sample() throws -> NaturalDayEnvironmentSample {
        fixedSample
    }

    func start(
        _ handler: @escaping @MainActor @Sendable (NaturalDaySignal) -> Void
    ) -> NaturalDayObservation {
        signalHandler = handler
        return NaturalDayObservation { [weak self] in
            self?.signalHandler = nil
        }
    }

    func update(
        instant: Date,
        timeZoneIdentifier: String? = nil,
        localeIdentifier: String? = nil,
        signal: NaturalDaySignal = .manual
    ) {
        fixedSample = NaturalDayEnvironmentSample(
            instant: instant,
            timeZoneIdentifier: timeZoneIdentifier ?? fixedSample.timeZoneIdentifier,
            localeIdentifier: localeIdentifier ?? fixedSample.localeIdentifier
        )
        signalHandler?(signal)
    }
}

@MainActor
enum NaturalDayEnvironmentFactory {
    private static let fixedFlags = [
        "--e2e-fixed-instant",
        "--e2e-fixed-time-zone",
        "--e2e-fixed-locale"
    ]

    static func make(
        arguments: [String],
        bundleIdentifier: String?
    ) throws -> any NaturalDayEnvironment {
        let permitsFixedClock = (try? NoonmarkRuntimeProfile.resolve(
            bundleIdentifier: bundleIdentifier
        ).permitsFixedNaturalDayArguments) == true
        let containsFixedFlag = fixedFlags.contains { arguments.contains($0) }
        guard permitsFixedClock || containsFixedFlag == false else {
            throw NaturalDayBootstrapError.fixedClockRequiresAuthorizedBundle
        }
        guard permitsFixedClock else {
            return SystemNaturalDayEnvironment()
        }

        let instantText = commandLineValue(
            after: "--e2e-fixed-instant",
            in: arguments
        ) ?? "2026-07-05T12:00:00-04:00"
        let timeZoneIdentifier = commandLineValue(
            after: "--e2e-fixed-time-zone",
            in: arguments
        ) ?? "America/New_York"
        let localeIdentifier = commandLineValue(
            after: "--e2e-fixed-locale",
            in: arguments
        ) ?? "zh_Hans_SG"

        let formatter = ISO8601DateFormatter()
        guard let instant = formatter.date(from: instantText) else {
            throw NaturalDayBootstrapError.invalidFixedInstant(instantText)
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw NaturalDayBootstrapError.invalidFixedTimeZone(timeZoneIdentifier)
        }
        return FixedNaturalDayEnvironment(
            instant: instant,
            timeZoneIdentifier: timeZoneIdentifier,
            localeIdentifier: localeIdentifier
        )
    }

    private static func commandLineValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

enum NaturalDayBootstrapError: LocalizedError {
    case fixedClockRequiresAuthorizedBundle
    case invalidFixedInstant(String)
    case invalidFixedTimeZone(String)

    var errorDescription: String? {
        switch self {
        case .fixedClockRequiresAuthorizedBundle:
            "Fixed natural-day arguments require the E2E or Demo runtime profile"
        case let .invalidFixedInstant(value):
            "Invalid E2E fixed instant: \(value)"
        case let .invalidFixedTimeZone(value):
            "Invalid E2E fixed time zone: \(value)"
        }
    }
}
