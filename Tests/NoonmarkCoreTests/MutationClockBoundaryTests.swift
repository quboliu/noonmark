@testable import NoonmarkCore
import XCTest

final class MutationClockBoundaryTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testReferenceEqualToFrontierAdvancesByOneRepresentableInstant() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "同一时钟前沿", now: base)

        let next = try engine.nextMutationDate(reference: base)

        XCTAssertEqual(
            next.timeIntervalSinceReferenceDate,
            base.timeIntervalSinceReferenceDate.nextUp
        )
    }

    func testThemeLanguageClockParticipatesInPersistedFrontier() throws {
        let remoteFuture = base.addingTimeInterval(1000)
        var snapshot = NoonmarkEngine().snapshot()
        snapshot.preferences = AppPreferences(
            theme: .warmPaper,
            language: .english,
            themeLanguageUpdatedAt: remoteFuture
        )
        let engine = try NoonmarkEngine(snapshot: snapshot)

        let localMutation = try engine.nextMutationDate(reference: base)

        XCTAssertEqual(
            localMutation.timeIntervalSinceReferenceDate.bitPattern,
            remoteFuture.timeIntervalSinceReferenceDate.nextUp.bitPattern
        )
    }

    func testTaskCycleSeriesClockParticipatesInPersistedFrontier() throws {
        let source = NoonmarkEngine()
        let today = LocalDate("2026-07-20")
        let seriesID = try source.createTaskCycleSeries(
            title: "远端周期计划",
            startDate: today,
            endDate: LocalDate("2026-07-21"),
            schedule: .daily,
            today: today,
            now: base
        )
        let remoteFuture = base.addingTimeInterval(1000)
        var snapshot = source.snapshot()
        let index = try XCTUnwrap(
            snapshot.taskCycleSeries.firstIndex {
                $0.id == seriesID
            }
        )
        let series = snapshot.taskCycleSeries[index]
        snapshot.taskCycleSeries[index] = TaskCycleSeries(
            id: series.id,
            title: series.title,
            descriptionText: series.descriptionText,
            startDate: series.startDate,
            endDate: series.endDate,
            schedule: series.schedule,
            cancellationFacts: series.cancellationFacts,
            createdAt: series.createdAt,
            updatedAt: remoteFuture
        )
        let engine = try NoonmarkEngine(snapshot: snapshot)

        let localMutation = try engine.nextMutationDate(
            reference: base.addingTimeInterval(500)
        )

        XCTAssertEqual(
            localMutation.timeIntervalSinceReferenceDate.bitPattern,
            remoteFuture.timeIntervalSinceReferenceDate.nextUp.bitPattern
        )
    }

    func testEveryNonFiniteReferenceFailsClosed() {
        let engine = NoonmarkEngine()

        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(
                try engine.nextMutationDate(
                    reference: Date(
                        timeIntervalSinceReferenceDate: seconds
                    )
                )
            )
        }
    }

    func testSnapshotRejectsNonFiniteThemeLanguageClock() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            var snapshot = NoonmarkEngine().snapshot()
            snapshot.preferences = AppPreferences(
                themeLanguageUpdatedAt: Date(
                    timeIntervalSinceReferenceDate: seconds
                )
            )

            XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput(
                        "app preferences contain an invalid theme and language version"
                    )
                )
            }
            XCTAssertThrowsError(try NoonmarkEngine(snapshot: snapshot))
        }
    }

    func testNonMaximumNonFinitePersistedDateFailsClosed() throws {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            let engine = NoonmarkEngine()
            _ = try engine.createPoolTask(
                title: "有限全局前沿",
                now: base.addingTimeInterval(100)
            )
            let categoryID = TaskCategoryID()
            let malformedCategory = TaskCategory(
                id: categoryID,
                name: "非有限分类时钟",
                colorHex: "#2A6FDB",
                now: Date(timeIntervalSinceReferenceDate: seconds)
            )
            engine.classificationState = TaskClassificationState(
                categories: [categoryID: malformedCategory]
            )

            XCTAssertThrowsError(
                try engine.nextMutationDate(reference: base)
            )
        }
    }

    func testNestedNonFiniteClassificationDateFailsClosed() throws {
        let engine = NoonmarkEngine()
        let categoryID = TaskCategoryID()
        var malformedCategory = TaskCategory(
            id: categoryID,
            name: "嵌套分类时钟",
            colorHex: "#2A6FDB",
            now: base
        )
        malformedCategory.nameVersions[0].validUntil = Date(
            timeIntervalSinceReferenceDate: .infinity
        )
        engine.classificationState = TaskClassificationState(
            categories: [categoryID: malformedCategory]
        )

        XCTAssertThrowsError(
            try engine.nextMutationDate(
                reference: base.addingTimeInterval(100)
            )
        )
    }

    func testGreatestFiniteFrontierFailsWhenItCannotAdvance() throws {
        let engine = NoonmarkEngine()
        let frontier = Date(
            timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude
        )
        _ = try engine.createPoolTask(
            title: "不可继续前进的时钟",
            now: frontier
        )

        XCTAssertThrowsError(
            try engine.nextMutationDate(reference: base)
        )
    }
}
