import Foundation
import NoonmarkCore
@testable import NoonmarkDayContext
import XCTest

@MainActor
final class NaturalDayContextTests: XCTestCase {
    func testMomentMapsOneSampleToTheSamplesTimeZoneAndLocale() throws {
        let instant = try makeInstant("2026-07-15T02:30:00Z")
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: instant,
                timeZoneIdentifier: "America/New_York",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)

        let moment = try context.moment()

        XCTAssertEqual(moment.instant, instant)
        XCTAssertEqual(moment.today, LocalDate("2026-07-14"))
        XCTAssertEqual(moment.state.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(moment.state.localeIdentifier, "en_SG")
    }

    func testSameInstantCanBelongToDifferentNaturalDays() throws {
        let instant = try makeInstant("2026-07-15T02:30:00Z")
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: instant,
                timeZoneIdentifier: "America/New_York",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)
        XCTAssertEqual(try context.moment().today, LocalDate("2026-07-14"))

        environment.sampleResult = .success(
            .init(
                instant: instant,
                timeZoneIdentifier: "Asia/Singapore",
                localeIdentifier: "en_SG"
            )
        )

        XCTAssertEqual(try context.moment().today, LocalDate("2026-07-15"))
    }

    func testObserverReceivesCurrentMomentThenEveryFreshSignal() throws {
        let beforeMidnight = try makeInstant("2026-07-15T03:59:59Z")
        let afterMidnight = try makeInstant("2026-07-15T04:00:00Z")
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: beforeMidnight,
                timeZoneIdentifier: "America/New_York",
                localeIdentifier: "zh_Hans_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)
        var events: [NaturalDayEvent] = []

        let observation = context.observe { events.append($0) }
        environment.sampleResult = .success(
            .init(
                instant: afterMidnight,
                timeZoneIdentifier: "America/New_York",
                localeIdentifier: "zh_Hans_SG"
            )
        )
        environment.send(.midnight)
        environment.send(.calendarDayChanged)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].refreshedMoment?.today, LocalDate("2026-07-14"))
        XCTAssertEqual(events[0].signal, .subscription)
        XCTAssertEqual(events[1].refreshedMoment?.today, LocalDate("2026-07-15"))
        XCTAssertEqual(events[1].signal, .midnight)
        XCTAssertEqual(events[2].refreshedMoment?.today, LocalDate("2026-07-15"))
        XCTAssertEqual(events[2].signal, .calendarDayChanged)
        observation.cancel()
    }

    func testSamplingFailureReportsLastKnownMomentAndCanRecover() throws {
        let initial = try makeInstant("2026-07-15T12:00:00Z")
        let recovered = try makeInstant("2026-07-16T12:00:00Z")
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: initial,
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)
        var events: [NaturalDayEvent] = []
        let observation = context.observe { events.append($0) }

        environment.sampleResult = .failure(TestEnvironmentError.unavailable)
        environment.send(.wake)
        environment.sampleResult = .success(
            .init(
                instant: recovered,
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_SG"
            )
        )
        environment.send(.applicationBecameActive)

        guard case let .failed(failure, lastKnown, signal) = events[1] else {
            return XCTFail("Expected a failed event")
        }
        XCTAssertEqual(failure, .environmentUnavailable("unavailable"))
        XCTAssertEqual(lastKnown?.instant, initial)
        XCTAssertEqual(signal, .wake)
        XCTAssertEqual(events[2].refreshedMoment?.instant, recovered)
        observation.cancel()
    }

    func testInvalidTimeZoneFailsClosed() throws {
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: try makeInstant("2026-07-15T12:00:00Z"),
                timeZoneIdentifier: "Not/A_Time_Zone",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)

        XCTAssertThrowsError(try context.moment()) { error in
            XCTAssertEqual(error as? NaturalDayFailure, .invalidTimeZone("Not/A_Time_Zone"))
        }
    }

    func testOffsetUsesStrictGregorianCivilDateArithmetic() throws {
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: try makeInstant("2026-07-15T12:00:00Z"),
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)

        XCTAssertEqual(
            try context.offset(LocalDate("2024-02-28"), byDays: 1),
            LocalDate("2024-02-29")
        )
        XCTAssertEqual(
            try context.offset(LocalDate("2024-02-29"), byDays: 1),
            LocalDate("2024-03-01")
        )
        XCTAssertThrowsError(
            try context.offset(LocalDate(year: 2026, month: 2, day: 31), byDays: 1)
        ) { error in
            XCTAssertEqual(
                error as? NaturalDayFailure,
                .invalidLocalDate(LocalDate(year: 2026, month: 2, day: 31))
            )
        }
    }

    func testCancelledObservationReceivesNoFurtherSignalsAndCancellationIsIdempotent() throws {
        let environment = ManualNaturalDayEnvironment(
            sample: .init(
                instant: try makeInstant("2026-07-15T12:00:00Z"),
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_SG"
            )
        )
        let context = NaturalDayContext(environment: environment)
        var events: [NaturalDayEvent] = []

        let observation = context.observe { events.append($0) }
        observation.cancel()
        observation.cancel()
        environment.send(.manual)

        XCTAssertEqual(events.count, 1)
    }

    private func makeInstant(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw TestEnvironmentError.invalidFixture
        }
        return date
    }
}

private extension NaturalDayEvent {
    var refreshedMoment: NaturalDayMoment? {
        guard case let .refreshed(moment, _) = self else { return nil }
        return moment
    }

    var signal: NaturalDaySignal {
        switch self {
        case let .refreshed(_, signal), let .failed(_, _, signal):
            signal
        }
    }
}

private enum TestEnvironmentError: Error, LocalizedError {
    case unavailable
    case invalidFixture

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "unavailable"
        case .invalidFixture:
            "invalid fixture"
        }
    }
}

@MainActor
private final class ManualNaturalDayEnvironment: NaturalDayEnvironment {
    var sampleResult: Result<NaturalDayEnvironmentSample, Error>
    private var signalHandler: (@MainActor @Sendable (NaturalDaySignal) -> Void)?

    init(sample: NaturalDayEnvironmentSample) {
        sampleResult = .success(sample)
    }

    func sample() throws -> NaturalDayEnvironmentSample {
        try sampleResult.get()
    }

    func start(
        _ handler: @escaping @MainActor @Sendable (NaturalDaySignal) -> Void
    ) -> NaturalDayObservation {
        signalHandler = handler
        return NaturalDayObservation { [weak self] in
            self?.signalHandler = nil
        }
    }

    func send(_ signal: NaturalDaySignal) {
        signalHandler?(signal)
    }
}
