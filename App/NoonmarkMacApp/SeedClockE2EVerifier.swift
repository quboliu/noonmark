import Foundation
import NoonmarkCore

@MainActor
enum SeedClockE2EVerifier {
    static func run(on store: NoonmarkStore, resultURL: URL) {
        let result: String
        do {
            let snapshot = store.engine.snapshot()
            _ = try NoonmarkEngine(snapshot: snapshot)
            try expectDayCreationPrecedesTraces(in: store.engine)
            try expectClassificationAuditChronology(in: snapshot.classifications)
            try expectRelativeDateEnvelope(
                in: store.engine,
                today: store.today
            )
            try expectCompletion(
                title: "回复设计合同邮件",
                expected: timestamp(
                    on: NoonmarkStore.offset(store.today, by: -2),
                    hour: 11,
                    minute: 20
                ),
                in: store.engine
            )
            try expectCompletion(
                title: "写本周周报",
                expected: timestamp(
                    on: NoonmarkStore.offset(store.today, by: -1),
                    hour: 17,
                    minute: 45
                ),
                in: store.engine
            )
            try expectCompletion(
                title: "晨跑 5 公里",
                expected: timestamp(on: store.today, hour: 7, minute: 36),
                in: store.engine
            )
            try expectFuturePlan(
                title: "准备周一站会要点",
                expectedDate: NoonmarkStore.offset(store.today, by: 1),
                in: store.engine
            )
            try expectFuturePlan(
                title: "整理六月发票报销",
                expectedDate: NoonmarkStore.offset(store.today, by: 2),
                in: store.engine
            )
            try expectFuturePlan(
                title: "预订团队聚餐餐厅",
                expectedDate: NoonmarkStore.offset(store.today, by: 1),
                in: store.engine
            )
            try expectOKRProgressAndNote(
                in: store.engine,
                today: store.today
            )
            result = "ok"
        } catch {
            result = "failed: \(error.localizedDescription)"
        }

        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Noonmark seed-clock E2E result write failed: %@", String(describing: error))
        }
    }

    private static func expectDayCreationPrecedesTraces(
        in engine: NoonmarkEngine
    ) throws {
        for trace in engine.traces.values {
            guard let day = engine.days[trace.date], day.createdAt <= trace.createdAt else {
                throw SeedClockE2EError.dayCreatedAfterTrace(trace.date.description)
            }
        }
    }

    private static func expectClassificationAuditChronology(
        in state: TaskClassificationState
    ) throws {
        var facts = state.changeRecords
            .filter(\.advancesStateRevision)
            .map {
                ClassificationAuditFact(
                    revision: $0.revision,
                    timestamp: $0.committedAt
                )
            }
        facts.append(contentsOf: state.snapshotEventsByTraceID.values
            .flatMap { $0 }
            .map {
                ClassificationAuditFact(
                    revision: $0.revision,
                    timestamp: $0.capturedAt
                )
            })
        facts.sort { $0.revision < $1.revision }

        guard facts.count == Int(state.revision),
              facts.enumerated().allSatisfy({ index, fact in
                  fact.revision == UInt64(index + 1)
              }),
              zip(facts, facts.dropFirst()).allSatisfy({ pair in
                  pair.0.timestamp <= pair.1.timestamp
              })
        else {
            throw SeedClockE2EError.classificationAuditMovedBackwards
        }
    }

    private static func expectRelativeDateEnvelope(
        in engine: NoonmarkEngine,
        today: LocalDate
    ) throws {
        let earliest = NoonmarkStore.offset(today, by: -4)
        let tomorrow = NoonmarkStore.offset(today, by: 1)
        let latest = NoonmarkStore.offset(today, by: 2)
        guard engine.traces.values.allSatisfy({ trace in
            trace.date >= earliest && trace.date <= latest
        }) else {
            throw SeedClockE2EError.traceOutsideRelativeDateEnvelope
        }
        guard engine.traces.values.allSatisfy({ trace in
            if trace.date > today {
                return (trace.date == tomorrow || trace.date == latest)
                    && trace.status == .pending
            }
            return trace.date == today || trace.status != .pending
        }) else {
            throw SeedClockE2EError.traceStatusOutsideRelativeDateEnvelope
        }
    }

    private static func expectOKRProgressAndNote(
        in engine: NoonmarkEngine,
        today: LocalDate
    ) throws {
        let progressTime = try timestamp(
            on: today,
            hour: 14,
            minute: 0
        )
        let noteTime = try timestamp(
            on: today,
            hour: 14,
            minute: 20
        )
        guard let definition = engine.definitions.values.first(where: {
            $0.title == "整理 Q3 OKR 草案"
        }), let trace = engine.traces.values.first(where: {
            $0.definitionID == definition.id && $0.status == .pending
        }), trace.manualProgressPercent == 30,
            trace.contentUpdatedAt == progressTime,
            trace.activeNoteEntries.count == 1,
            trace.activeNoteEntries[0].body == "等数据组下午的留存看板再定第 2 个 KR 的口径。",
            trace.activeNoteEntries[0].createdAt == noteTime,
            trace.activeNoteEntries[0].updatedAt == noteTime
        else {
            throw SeedClockE2EError.okrTimelineMismatch
        }
    }

    private static func expectFuturePlan(
        title: String,
        expectedDate: LocalDate,
        in engine: NoonmarkEngine
    ) throws {
        guard let definition = engine.definitions.values.first(where: {
            $0.title == title
        }), let trace = engine.traces.values.first(where: {
            $0.definitionID == definition.id
        }), trace.date == expectedDate,
            trace.status == .pending
        else {
            throw SeedClockE2EError.futurePlanMismatch(title)
        }
    }

    private static func expectCompletion(
        title: String,
        expected: Date,
        in engine: NoonmarkEngine
    ) throws {
        guard let definition = engine.definitions.values.first(where: {
            $0.title == title
        }), let trace = engine.traces.values.first(where: {
            $0.definitionID == definition.id && $0.status == .completed
        }), trace.completedAt == expected else {
            throw SeedClockE2EError.completionMismatch(title)
        }
    }

    private static func timestamp(
        on date: LocalDate,
        hour: Int,
        minute: Int
    ) throws -> Date {
        // Must match seed()'s deterministic fixture timezone, never the host timezone.
        guard let timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60) else {
            throw SeedClockE2EError.invalidFixtureCalendar
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        guard let value = calendar.date(from: DateComponents(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: hour,
            minute: minute
        )) else {
            throw SeedClockE2EError.invalidFixtureCalendar
        }
        return value
    }
}

private struct ClassificationAuditFact {
    let revision: UInt64
    let timestamp: Date
}

private enum SeedClockE2EError: LocalizedError {
    case completionMismatch(String)
    case dayCreatedAfterTrace(String)
    case futurePlanMismatch(String)
    case classificationAuditMovedBackwards
    case okrTimelineMismatch
    case traceOutsideRelativeDateEnvelope
    case traceStatusOutsideRelativeDateEnvelope
    case invalidFixtureCalendar

    var errorDescription: String? {
        switch self {
        case let .completionMismatch(title):
            "seed completion time mismatch: \(title)"
        case let .dayCreatedAfterTrace(date):
            "seed day was created after one of its traces: \(date)"
        case let .futurePlanMismatch(title):
            "seed future plan date mismatch: \(title)"
        case .classificationAuditMovedBackwards:
            "seed classification audit time moved backwards"
        case .okrTimelineMismatch:
            "seed OKR progress or note time mismatch"
        case .traceOutsideRelativeDateEnvelope:
            "seed trace fell outside today - 4 through today + 2"
        case .traceStatusOutsideRelativeDateEnvelope:
            "seed trace status did not match its relative date"
        case .invalidFixtureCalendar:
            "seed fixture calendar is invalid"
        }
    }
}
