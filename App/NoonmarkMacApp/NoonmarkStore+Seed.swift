import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore

extension NoonmarkStore {
    func seed() throws {
        let day3 = today
        let day0 = Self.offset(day3, by: -4)
        let dayMinus3 = Self.offset(day3, by: -3)
        let day1 = Self.offset(day3, by: -2)
        let day2 = Self.offset(day3, by: -1)
        let day4 = Self.offset(day3, by: 1)
        let day5 = Self.offset(day3, by: 2)
        // Deterministic fixture timezone: every seeded Date uses this fixed UTC-04 offset
        // so snapshot and Audit bytes never depend on the host's current time zone.
        guard let seedTimeZone = TimeZone(secondsFromGMT: -4 * 60 * 60) else {
            preconditionFailure("Seed time zone must be available")
        }
        var seedCalendar = Calendar(identifier: .gregorian)
        seedCalendar.locale = Locale(identifier: "en_US_POSIX")
        seedCalendar.timeZone = seedTimeZone
        func eventTime(_ date: LocalDate, hour: Int, minute: Int) -> Date {
            var components = DateComponents()
            components.year = date.year
            components.month = date.month
            components.day = date.day
            components.hour = hour
            components.minute = minute
            guard let timestamp = seedCalendar.date(from: components),
                  timestamp.timeIntervalSinceReferenceDate.isFinite
            else {
                preconditionFailure("Seed event time must be a finite Gregorian date")
            }
            return timestamp
        }
        let seedStart = eventTime(day0, hour: 8, minute: 0)
        var nextSeedSetupTime = seedStart
        var lastReplayedEventTime: Date?
        func seedNow(at eventTime: Date? = nil) -> Date {
            if let eventTime {
                precondition(eventTime.timeIntervalSinceReferenceDate.isFinite)
                if let lastReplayedEventTime {
                    precondition(
                        eventTime >= lastReplayedEventTime,
                        "Seed domain events must be replayed in timestamp order"
                    )
                }
                lastReplayedEventTime = eventTime
                return eventTime
            }
            let timestamp = nextSeedSetupTime
            precondition(timestamp.timeIntervalSinceReferenceDate.isFinite)
            nextSeedSetupTime = timestamp.addingTimeInterval(1)
            return timestamp
        }
        func setClassification(
            chainID: TaskChainID,
            category: (name: String, colorHex: String),
            labels: [(name: String, colorHex: String)]
        ) throws {
            let interactionID = UUID()
            let timestamp = seedNow()
            let plan = try engine.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .new(name: category.name, colorHex: category.colorHex),
                        labels: labels.map { .new(name: $0.name, colorHex: $0.colorHex) }
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: timestamp
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .confirmedByUser(confirming: plan, decisionID: interactionID),
                now: timestamp
            )
        }
        do {
            // Phase 1: create every setup fact before replaying any domain event. The
            // setup clock is independent from explicit business time and ends before
            // the first event at 08:05, so later audit revisions cannot move backwards.
            let okr = try engine.createPoolTask(
                title: "整理 Q3 OKR 草案",
                descriptionText: "汇总三条产品线负责人给的季度目标，收敛成不超过 3 个 O、每个 O 配 3 个可量化 KR。",
                now: seedNow()
            )
            try setClassification(
                chainID: okr,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let launchScript = try engine.createPoolTask(title: "给发布会准备演示脚本", descriptionText: "准备发布会现场演示脚本。", now: seedNow())
            let physical = try engine.createPoolTask(title: "预约年度体检", descriptionText: "预约年度体检时间。", now: seedNow())
            try setClassification(
                chainID: physical,
                category: ("生活", "#D1477A"),
                labels: [("健康", "#0E9488"), ("年度", "#E0851B")]
            )
            let wireframe = try engine.createPoolTask(title: "画首页线框图", descriptionText: "日历完成样例任务。", now: seedNow())
            let repository = try engine.createPoolTask(title: "搭建项目仓库与 CI", descriptionText: "日历完成样例任务。", now: seedNow())
            let rust = try engine.createPoolTask(title: "学习 Rust 基础语法", descriptionText: "废弃样例任务。", now: seedNow())
            let contract = try engine.createPoolTask(title: "回复设计合同邮件", descriptionText: "确认合同条款并回复对方。", now: seedNow())
            let iconExport = try engine.createPoolTask(title: "修复图标导出脚本", descriptionText: "修复图标资源导出脚本。", now: seedNow())
            try setClassification(
                chainID: iconExport,
                category: ("工程", "#2A6FDB"),
                labels: []
            )
            let weeklyReport = try engine.createPoolTask(title: "写本周周报", descriptionText: "整理本周进展和风险。", now: seedNow())
            try setClassification(
                chainID: weeklyReport,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let pricing = try engine.createPoolTask(title: "调研竞品定价", descriptionText: "旧任务范围过大，需要变更为可交付对比表。", now: seedNow())
            let visual = try engine.createPoolTask(title: "制作发布会主视觉", descriptionText: "推进发布会主视觉定稿。", now: seedNow())
            try setClassification(
                chainID: visual,
                category: ("工程", "#2A6FDB"),
                labels: []
            )
            let onboarding = try engine.createPoolTask(title: "审阅 onboarding 三屏文案", descriptionText: "审阅 onboarding 三屏文案。", now: seedNow())
            try setClassification(
                chainID: onboarding,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let running = try engine.createPoolTask(title: "晨跑 5 公里", descriptionText: "完成晨跑。", now: seedNow())
            try setClassification(
                chainID: running,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let downloads = try engine.createPoolTask(title: "清理下载文件夹", descriptionText: "清理下载文件夹。", now: seedNow())
            try setClassification(
                chainID: downloads,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let reading = try engine.createPoolTask(title: "读《卡片笔记写作法》第三章", descriptionText: "任务池样例任务。", now: seedNow())
            try setClassification(
                chainID: reading,
                category: ("学习", "#7C5CFF"),
                labels: [
                    ("阅读", "#0E9488"),
                    ("卡片笔记", "#2A6FDB"),
                    ("写作", "#D1477A"),
                    ("第三章", "#E0851B")
                ]
            )
            let animationAPI = try engine.createPoolTask(title: "调研 SwiftUI 动画 API", descriptionText: "任务池样例任务。", now: seedNow())
            try setClassification(
                chainID: animationAPI,
                category: ("工程", "#2A6FDB"),
                labels: [("SwiftUI", "#7C5CFF"), ("动画", "#0E9488")]
            )

            let standup = try engine.createPoolTask(title: "准备周一站会要点", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: standup,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let invoice = try engine.createPoolTask(title: "整理六月发票报销", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: invoice,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let dinner = try engine.createPoolTask(title: "预订团队聚餐餐厅", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: dinner,
                category: ("生活", "#D1477A"),
                labels: []
            )

            precondition(
                nextSeedSetupTime < eventTime(day0, hour: 8, minute: 5),
                "Seed setup facts must precede the first domain event"
            )

            // Phase 2: replay domain events in global timestamp order. Calls sharing
            // one timestamp keep their established relative order for deterministic
            // priorities, but no explicit business timestamp is globally clamped.
            let okrDay0 = try engine.scheduleFromPool(
                chainID: okr,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 8, minute: 5))
            )
            let repositoryTrace = try engine.scheduleFromPool(
                chainID: repository,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 8, minute: 30))
            )
            try engine.markCompleted(
                traceID: repositoryTrace,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 9, minute: 10))
            )
            let rustTrace = try engine.scheduleFromPool(
                chainID: rust,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 10, minute: 0))
            )
            try engine.abandonChain(
                from: rustTrace,
                now: seedNow(at: eventTime(day0, hour: 10, minute: 1))
            )

            _ = try engine.scheduleFromPool(
                chainID: launchScript,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 8, minute: 0))
            )
            let physicalTrace = try engine.scheduleFromPool(
                chainID: physical,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 0))
            )
            try engine.returnToPool(
                traceID: physicalTrace,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 1))
            )
            let wireframeTrace = try engine.scheduleFromPool(
                chainID: wireframe,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 5))
            )
            try engine.markCompleted(
                traceID: wireframeTrace,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 16, minute: 30))
            )

            try engine.settleDays(
                upTo: day1,
                now: seedNow(at: eventTime(day1, hour: 0, minute: 1))
            )
            let okrDay1 = try engine.continueTrace(
                traceID: okrDay0,
                targetDate: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 8, minute: 0))
            )
            let okrToday = try engine.continueTrace(
                traceID: okrDay1,
                targetDate: day3,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 8, minute: 1))
            )
            let contractTrace = try engine.scheduleFromPool(
                chainID: contract,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let weeklyDay1 = try engine.scheduleFromPool(
                chainID: weeklyReport,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let visualDay1 = try engine.scheduleFromPool(
                chainID: visual,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let visualReference = try engine.addSubtask(
                traceID: visualDay1,
                title: "收集视觉参考",
                difficulty: .simple,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 1))
            )
            _ = try engine.addSubtask(
                traceID: visualDay1,
                title: "出 3 版草图",
                difficulty: .hard,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 2))
            )
            try engine.markCompleted(
                traceID: contractTrace,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 11, minute: 20))
            )
            try engine.completeSubtask(
                visualReference,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 15, minute: 20))
            )
            let weeklyDay2 = try engine.continueTrace(
                traceID: weeklyDay1,
                targetDate: day2,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 18, minute: 0))
            )
            let visualDay2 = try engine.continueTrace(
                traceID: visualDay1,
                targetDate: day2,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 18, minute: 0))
            )

            let iconDay2 = try engine.scheduleFromPool(
                chainID: iconExport,
                date: day2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 9, minute: 0))
            )
            let pricingTrace = try engine.scheduleFromPool(
                chainID: pricing,
                date: day2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 9, minute: 0))
            )
            try engine.setManualProgress(
                traceID: iconDay2,
                percent: 45,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 10, minute: 0))
            )
            _ = try engine.changeTrace(
                traceID: pricingTrace,
                newTitle: "输出竞品定价对比表",
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 10, minute: 0))
            )
            if let draftSubtask = engine.subtasks.values.first(where: {
                $0.traceID == visualDay2 && $0.title == "出 3 版草图"
            }) {
                try engine.completeSubtask(
                    draftSubtask.id,
                    today: day2,
                    now: seedNow(at: eventTime(day2, hour: 15, minute: 45))
                )
            }
            _ = try engine.addSubtask(
                traceID: visualDay2,
                title: "定稿并交付",
                difficulty: .medium,
                now: seedNow(at: eventTime(day2, hour: 15, minute: 46))
            )
            try engine.markCompleted(
                traceID: weeklyDay2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 17, minute: 45))
            )
            let iconToday = try engine.continueTrace(
                traceID: iconDay2,
                targetDate: day3,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 18, minute: 0))
            )
            let visualToday = try engine.continueTrace(
                traceID: visualDay2,
                targetDate: day3,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 18, minute: 0))
            )
            if engine.subtasks.values.contains(where: { $0.traceID == visualToday }) == false {
                _ = try engine.addSubtask(
                    traceID: visualToday,
                    title: "定稿并交付",
                    difficulty: .medium,
                    now: seedNow(at: eventTime(day2, hour: 18, minute: 1))
                )
            }

            try engine.settleDays(
                upTo: day3,
                now: seedNow(at: eventTime(day3, hour: 0, minute: 1))
            )
            engine.updateDailyReview(
                date: day1,
                summary: "合同邮件处理完毕；OKR 草案低估了工作量，明天优先。",
                unfinishedReason: "OKR 依赖的数据下午才拿到，被会议切碎。",
                tomorrowNote: "上午先做 OKR，别先开邮箱。",
                now: seedNow(at: eventTime(day3, hour: 0, minute: 2))
            )
            engine.updateDailyReview(
                date: day2,
                summary: "周报和图标脚本推进顺利；竞品调研范围太大，拆成了对比表任务。",
                unfinishedReason: "竞品对比表低估了整理时间。",
                tomorrowNote: "对比表先列框架再填数据。",
                now: seedNow(at: eventTime(day3, hour: 0, minute: 3))
            )

            let runningTrace = try engine.scheduleFromPool(
                chainID: running,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 7, minute: 0))
            )
            try engine.markCompleted(
                traceID: runningTrace,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 7, minute: 36))
            )
            let onboardingTrace = try engine.scheduleFromPool(
                chainID: onboarding,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: downloads,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 0))
            )
            let headline = try engine.addSubtask(
                traceID: onboardingTrace,
                title: "首屏标题与副标题",
                difficulty: .simple,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 1))
            )
            _ = try engine.addSubtask(
                traceID: onboardingTrace,
                title: "通知权限请求文案",
                difficulty: .medium,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 2))
            )
            try engine.setManualProgress(
                traceID: iconToday,
                percent: 45,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 9, minute: 0))
            )
            try engine.completeSubtask(
                headline,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 9, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: standup,
                date: day4,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: invoice,
                date: day5,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 1))
            )
            _ = try engine.scheduleFromPool(
                chainID: dinner,
                date: day4,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 2))
            )
            try engine.setManualProgress(
                traceID: okrToday,
                percent: 30,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 14, minute: 0))
            )
            _ = try engine.appendTraceNote(
                traceID: okrToday,
                body: "等数据组下午的留存看板再定第 2 个 KR 的口径。",
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 14, minute: 20))
            )
            engine.updateDailyReview(
                date: day3,
                summary: "",
                unfinishedReason: "",
                tomorrowNote: "",
                now: seedNow(at: eventTime(day3, hour: 15, minute: 0))
            )
        } catch {
            throw NoonmarkSeedError(underlying: error)
        }
    }
}

private struct NoonmarkSeedError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        "Seed data failed: \(underlying.localizedDescription)"
    }
}
