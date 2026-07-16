import NoonmarkCore

public enum CalendarDayPosition: Equatable, Sendable {
    case history
    case today
    case future
}

public struct CalendarInsightCopy: Equatable, Sendable {
    private let language: AppLanguage

    package init(language: AppLanguage) {
        self.language = language
    }

    public func riskSummary(
        position: CalendarDayPosition,
        unresolved: Int,
        pending: Int,
        total: Int
    ) -> String {
        if position == .history, unresolved > 0 {
            return localized(
                chinese: "历史日有 \(unresolved) 项未闭环或废弃，适合补写原因。",
                english: "This past day has \(unresolved) unresolved or dropped item\(unresolved == 1 ? "" : "s"); add the reason to the review."
            )
        }
        if position == .today, pending >= 4 {
            return localized(
                chinese: "待完成任务偏多。先调整当日优先级；需要留到后续日期时，在日结束后使用延续复制。",
                english: "There are many pending tasks. Reorder today's priorities; after day end, use continuation copying for work that continues later."
            )
        }
        if position == .future, pending >= 4 {
            return localized(
                chinese: "计划草稿偏多，可调整优先级或改期到其他未来日期。",
                english: "This plan draft is crowded; reorder it or reschedule items to other future dates."
            )
        }
        if position == .future, total == 0 {
            return localized(
                chinese: "未来日暂无计划，可保持空白或从任务池排期。",
                english: "This future day has no plans; leave it open or schedule from the Task Pool."
            )
        }
        if total == 0 {
            return localized(
                chinese: "当天没有任务记录。",
                english: "No tasks were recorded that day."
            )
        }
        return localized(
            chinese: "当天风险可控，重点看未完成和延续项。",
            english: "Risk is manageable; focus on unfinished and continued tasks."
        )
    }

    private func localized(chinese: String, english: String) -> String {
        language == .chinese ? chinese : english
    }
}

public extension AppPresentation {
    var calendarInsight: CalendarInsightCopy {
        CalendarInsightCopy(language: language)
    }
}
