import Foundation
import NoonmarkCore

public struct NaturalDayState: Equatable, Sendable {
    public let today: LocalDate
    public let timeZoneIdentifier: String
    public let localeIdentifier: String

    package init(
        today: LocalDate,
        timeZoneIdentifier: String,
        localeIdentifier: String
    ) {
        self.today = today
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localeIdentifier = localeIdentifier
    }
}

public struct NaturalDayMoment: Equatable, Sendable {
    public let instant: Date
    public let state: NaturalDayState

    public var today: LocalDate { state.today }

    package init(instant: Date, state: NaturalDayState) {
        self.instant = instant
        self.state = state
    }
}

public enum NaturalDaySignal: Equatable, Sendable {
    case subscription
    case midnight
    case calendarDayChanged
    case systemClockChanged
    case timeZoneChanged
    case localeChanged
    case wake
    case applicationBecameActive
    case manual
}

public enum NaturalDayFailure: Error, Equatable, Sendable {
    case invalidTimeZone(String)
    case invalidLocalDate(LocalDate)
    case dateArithmeticOverflow
    case environmentUnavailable(String)
}

extension NaturalDayFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidTimeZone(identifier):
            "Invalid time zone: \(identifier)"
        case let .invalidLocalDate(date):
            "Invalid Gregorian date: \(date)"
        case .dateArithmeticOverflow:
            "Gregorian date arithmetic exceeded its supported range"
        case let .environmentUnavailable(message):
            "Natural-day environment unavailable: \(message)"
        }
    }
}

public enum NaturalDayEvent: Equatable, Sendable {
    case refreshed(NaturalDayMoment, signal: NaturalDaySignal)
    case failed(
        NaturalDayFailure,
        lastKnown: NaturalDayMoment?,
        signal: NaturalDaySignal
    )
}

@MainActor
public final class NaturalDayObservation {
    private var cancellation: (@MainActor @Sendable () -> Void)?

    package init(
        _ cancellation: @escaping @MainActor @Sendable () -> Void
    ) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let operation = cancellation
        cancellation = nil
        operation?()
    }

    deinit {
        let operation = cancellation
        Task { @MainActor in
            operation?()
        }
    }
}

package struct NaturalDayEnvironmentSample: Equatable {
    package let instant: Date
    package let timeZoneIdentifier: String
    package let localeIdentifier: String

    package init(
        instant: Date,
        timeZoneIdentifier: String,
        localeIdentifier: String
    ) {
        self.instant = instant
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localeIdentifier = localeIdentifier
    }
}

@MainActor
package protocol NaturalDayEnvironment: AnyObject {
    func sample() throws -> NaturalDayEnvironmentSample

    func start(
        _ handler: @escaping @MainActor @Sendable (NaturalDaySignal) -> Void
    ) -> NaturalDayObservation
}

@MainActor
public final class NaturalDayContext {
    private let environment: any NaturalDayEnvironment
    private var environmentObservation: NaturalDayObservation?
    private var observers: [UUID: @MainActor @Sendable (NaturalDayEvent) -> Void] = [:]
    private var lastKnownMoment: NaturalDayMoment?

    package init(environment: any NaturalDayEnvironment) {
        self.environment = environment
    }

    public func moment() throws -> NaturalDayMoment {
        let moment = try Self.makeMoment(from: environment.sample())
        lastKnownMoment = moment
        return moment
    }

    public func observe(
        _ handler: @escaping @MainActor @Sendable (NaturalDayEvent) -> Void
    ) -> NaturalDayObservation {
        let identifier = UUID()
        observers[identifier] = handler
        startEnvironmentIfNeeded()

        do {
            let current = try moment()
            handler(.refreshed(current, signal: .subscription))
        } catch {
            handler(
                .failed(
                    Self.failure(from: error),
                    lastKnown: lastKnownMoment,
                    signal: .subscription
                )
            )
        }

        return NaturalDayObservation { [weak self] in
            self?.observers.removeValue(forKey: identifier)
        }
    }

    public func offset(_ date: LocalDate, byDays days: Int) throws -> LocalDate {
        try GregorianLocalDateArithmetic.offset(date, byDays: days)
    }

    private func startEnvironmentIfNeeded() {
        guard environmentObservation == nil else { return }
        environmentObservation = environment.start { [weak self] signal in
            self?.refresh(for: signal)
        }
    }

    private func refresh(for signal: NaturalDaySignal) {
        let event: NaturalDayEvent
        do {
            let current = try moment()
            event = .refreshed(current, signal: signal)
        } catch {
            event = .failed(
                Self.failure(from: error),
                lastKnown: lastKnownMoment,
                signal: signal
            )
        }
        for observer in observers.values {
            observer(event)
        }
    }

    private static func makeMoment(
        from sample: NaturalDayEnvironmentSample
    ) throws -> NaturalDayMoment {
        guard sample.instant.timeIntervalSinceReferenceDate.isFinite else {
            throw NaturalDayFailure.environmentUnavailable("non-finite instant")
        }
        guard let timeZone = TimeZone(identifier: sample.timeZoneIdentifier) else {
            throw NaturalDayFailure.invalidTimeZone(sample.timeZoneIdentifier)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: sample.instant
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw NaturalDayFailure.environmentUnavailable(
                "calendar did not produce a civil date"
            )
        }
        let today = LocalDate(year: year, month: month, day: day)
        guard strictDate(from: today, calendar: calendar) != nil else {
            throw NaturalDayFailure.invalidLocalDate(today)
        }
        return NaturalDayMoment(
            instant: sample.instant,
            state: NaturalDayState(
                today: today,
                timeZoneIdentifier: timeZone.identifier,
                localeIdentifier: sample.localeIdentifier
            )
        )
    }

    private static func strictDate(
        from localDate: LocalDate,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = localDate.year
        components.month = localDate.month
        components.day = localDate.day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == localDate.year,
              roundTrip.month == localDate.month,
              roundTrip.day == localDate.day
        else { return nil }
        return date
    }

    private static func failure(from error: Error) -> NaturalDayFailure {
        if let failure = error as? NaturalDayFailure {
            return failure
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription, description.isEmpty == false {
            return .environmentUnavailable(description)
        }
        return .environmentUnavailable(String(describing: error))
    }
}
