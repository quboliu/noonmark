import Foundation
import NoonmarkCore

@MainActor
struct E2EFixtureTimeline {
    let today: LocalDate

    private let interactionInstant: Date
    private let eventCount: Int
    private let firstInstant: Date
    private var issuedCount = 0
    private var isFinished = false

    init(store: NoonmarkStore, eventCount: Int) throws {
        guard eventCount > 0,
              let moment = store.prepareNaturalDayForUserMutation(),
              store.today == moment.today,
              moment.instant.timeIntervalSinceReferenceDate.isFinite
        else {
            throw Failure.invalidNaturalDay
        }
        let firstInstant = moment.instant.addingTimeInterval(
            -Double(eventCount)
        )
        guard firstInstant.timeIntervalSinceReferenceDate.isFinite,
              firstInstant < moment.instant
        else {
            throw Failure.invalidEventWindow
        }

        today = moment.today
        interactionInstant = moment.instant
        self.eventCount = eventCount
        self.firstInstant = firstInstant
    }

    mutating func nextInstant() throws -> Date {
        guard isFinished == false, issuedCount < eventCount else {
            throw Failure.exhausted
        }
        let instant = firstInstant.addingTimeInterval(
            Double(issuedCount)
        )
        guard instant.timeIntervalSinceReferenceDate.isFinite,
              instant < interactionInstant
        else {
            throw Failure.invalidEventWindow
        }
        issuedCount += 1
        return instant
    }

    mutating func finish() throws -> Date {
        guard isFinished == false, issuedCount == eventCount else {
            throw Failure.incomplete(
                expected: eventCount,
                actual: issuedCount
            )
        }
        isFinished = true
        return firstInstant.addingTimeInterval(
            Double(eventCount - 1)
        )
    }

    private enum Failure: LocalizedError {
        case exhausted
        case incomplete(expected: Int, actual: Int)
        case invalidEventWindow
        case invalidNaturalDay

        var errorDescription: String? {
            switch self {
            case .exhausted:
                "E2E fixture timeline issued more instants than declared"
            case let .incomplete(expected, actual):
                "E2E fixture timeline issued \(actual) of \(expected) instants"
            case .invalidEventWindow:
                "E2E fixture timeline could not precede its interaction clock"
            case .invalidNaturalDay:
                "E2E fixture timeline could not read a reconciled natural day"
            }
        }
    }
}
