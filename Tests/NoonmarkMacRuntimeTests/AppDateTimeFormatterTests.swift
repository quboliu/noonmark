import Foundation
import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class AppDateTimeFormatterTests: XCTestCase {
    private let date = LocalDate("2026-07-15")
    private let timeZone = TimeZone(identifier: "Asia/Singapore")!

    func testChineseAndEnglishDateStylesAreCompleteAndDoNotMixScripts() throws {
        let chinese = AppDateTimeFormatter(
            language: .chinese,
            timeZone: timeZone
        )
        let english = AppDateTimeFormatter(
            language: .english,
            timeZone: timeZone
        )

        XCTAssertEqual(try chinese.string(from: date, style: .monthDay), "7月15日")
        XCTAssertEqual(try chinese.string(from: date, style: .fullDate), "2026年7月15日")
        XCTAssertEqual(try chinese.string(from: date, style: .weekday), "周三")
        XCTAssertEqual(try chinese.string(from: date, style: .weekdayNarrow), "三")
        XCTAssertEqual(try chinese.string(from: date, style: .monthYear), "2026年7月")

        XCTAssertEqual(try english.string(from: date, style: .monthDay), "15 Jul")
        XCTAssertEqual(try english.string(from: date, style: .fullDate), "15 July 2026")
        XCTAssertEqual(try english.string(from: date, style: .weekday), "Wed")
        XCTAssertEqual(try english.string(from: date, style: .weekdayNarrow), "W")
        XCTAssertEqual(try english.string(from: date, style: .monthYear), "July 2026")
    }

    func testAccessibilityDateIncludesWeekdayWithoutViewSideConcatenation() throws {
        let chinese = AppDateTimeFormatter(language: .chinese, timeZone: timeZone)
        let english = AppDateTimeFormatter(language: .english, timeZone: timeZone)

        XCTAssertEqual(
            try chinese.string(from: date, style: .accessibilityFull),
            "2026年7月15日，周三"
        )
        XCTAssertEqual(
            try english.string(from: date, style: .accessibilityFull),
            "Wednesday, 15 July 2026"
        )
    }

    func testCalendarWeekdaySymbolsStartOnMondayInBothLanguages() {
        let chinese = AppDateTimeFormatter(language: .chinese, timeZone: timeZone)
        let english = AppDateTimeFormatter(language: .english, timeZone: timeZone)

        XCTAssertEqual(
            chinese.narrowWeekdaySymbolsStartingMonday(),
            ["一", "二", "三", "四", "五", "六", "日"]
        )
        XCTAssertEqual(
            english.narrowWeekdaySymbolsStartingMonday(),
            ["M", "T", "W", "T", "F", "S", "S"]
        )
    }

    func testInvalidGregorianDateIsRejectedInsteadOfNormalised() {
        let formatter = AppDateTimeFormatter(language: .english, timeZone: timeZone)
        let invalid = LocalDate(year: 2026, month: 2, day: 31)

        XCTAssertThrowsError(try formatter.string(from: invalid, style: .fullDate)) { error in
            XCTAssertEqual(
                error as? AppDateTimeFormattingError,
                .invalidLocalDate(invalid)
            )
        }
    }

    func testTimeFormattingUsesTheSelectedLanguageLocale() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = 2026
        components.month = 7
        components.day = 15
        components.hour = 20
        components.minute = 5
        let instant = try XCTUnwrap(components.date)

        let chinese = AppDateTimeFormatter(language: .chinese, timeZone: timeZone)
        let english = AppDateTimeFormatter(language: .english, timeZone: timeZone)
        XCTAssertEqual(chinese.string(from: instant, style: .shortTime), "20:05")
        XCTAssertFalse(english.string(from: instant, style: .shortTime).contains("时"))
        XCTAssertFalse(english.string(from: instant, style: .shortTime).contains("分"))
        XCTAssertEqual(
            chinese.string(from: instant, style: .dateAndTime),
            "2026-07-15 20:05"
        )
        let englishDateTime = english.string(from: instant, style: .dateAndTime)
        XCTAssertTrue(englishDateTime.contains("2026"))
        XCTAssertFalse(englishDateTime.range(of: "[\\p{Han}]", options: .regularExpression) != nil)
    }

    func testPickerDateConversionRoundTripsAtLocalNoonAcrossTimeZones() throws {
        let dates = [
            LocalDate("2024-02-29"),
            LocalDate("2026-03-08"),
            LocalDate("2026-11-01")
        ]
        let timeZones = [
            TimeZone(identifier: "America/New_York")!,
            TimeZone(identifier: "Asia/Singapore")!,
            TimeZone(identifier: "Pacific/Kiritimati")!
        ]

        for timeZone in timeZones {
            let formatter = AppDateTimeFormatter(
                language: .english,
                timeZone: timeZone
            )
            for localDate in dates {
                let foundationDate = try formatter.foundationDate(from: localDate)
                XCTAssertEqual(
                    try formatter.localDate(from: foundationDate),
                    localDate,
                    "Failed in \(timeZone.identifier)"
                )
            }
        }
    }
}
