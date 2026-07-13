import Foundation
import NoonmarkCore

public struct AIEvidence: Equatable, Sendable {
    public let metric: String
    public let value: Double
    public let unit: String
    public let fact: String
    public let relatedDates: [LocalDate]

    public init(metric: String, value: Double, unit: String, fact: String, relatedDates: [LocalDate] = []) {
        self.metric = metric
        self.value = value
        self.unit = unit
        self.fact = fact
        self.relatedDates = relatedDates
    }
}

public struct LocalInsightReport: Equatable, Sendable {
    public let evidence: [AIEvidence]
    public let facts: [String]

    public init(evidence: [AIEvidence], facts: [String]) {
        self.evidence = evidence
        self.facts = facts
    }
}

public struct LocalInsightAnalyzer: Sendable {
    public init() {}

    public func analyze(_ scope: AIScopeSnapshot) -> LocalInsightReport {
        let traces = uniqueTraceSnapshots(in: scope)
        var evidence: [AIEvidence] = []
        var facts: [String] = []

        if traces.isEmpty == false {
            let maxContinuationSeq = traces.map(\.trace.continuationSeq).max() ?? 0
            let continuedTraces = traces.filter { $0.trace.continuationSeq > 0 || $0.trace.status == .continued }
            if maxContinuationSeq > 0 || continuedTraces.isEmpty == false {
                let dates = uniqueDates(continuedTraces.map(\.trace.date))
                let fact = "范围内有 \(continuedTraces.count) 条日轨迹涉及延续，最高延续次数为 \(maxContinuationSeq)。"
                evidence.append(
                    AIEvidence(
                        metric: "max_continuation_seq",
                        value: Double(maxContinuationSeq),
                        unit: "次",
                        fact: fact,
                        relatedDates: dates
                    )
                )
                facts.append(fact)
            }

            let terminalTraces = traces.filter { [.completed, .unfinished, .continued, .abandoned].contains($0.trace.status) }
            if terminalTraces.isEmpty == false {
                let completedCount = terminalTraces.filter { $0.trace.status == .completed }.count
                let completionRate = Double(completedCount) / Double(terminalTraces.count)
                let fact = "范围内已结算轨迹 \(terminalTraces.count) 条，其中完成 \(completedCount) 条，完成率为 \(Int((completionRate * 100).rounded()))%。"
                evidence.append(
                    AIEvidence(
                        metric: "completion_rate",
                        value: completionRate,
                        unit: "ratio",
                        fact: fact,
                        relatedDates: uniqueDates(terminalTraces.map(\.trace.date))
                    )
                )
                facts.append(fact)
            }

            let partialProgress = traces.filter(\.subtaskProgress.isPartiallyCompleted)
            if partialProgress.isEmpty == false {
                let fact = "范围内有 \(partialProgress.count) 条日轨迹出现部分完成：已有子任务完成，但父任务仍不能完成。"
                evidence.append(
                    AIEvidence(
                        metric: "partial_progress_traces",
                        value: Double(partialProgress.count),
                        unit: "条",
                        fact: fact,
                        relatedDates: uniqueDates(partialProgress.map(\.trace.date))
                    )
                )
                facts.append(fact)
            }
        }

        if scope.unfinishedPool.isEmpty == false {
            let fact = "未完成池按任务链去重后有 \(scope.unfinishedPool.count) 条任务链仍需处理。"
            evidence.append(
                AIEvidence(
                    metric: "unfinished_chain_count",
                    value: Double(scope.unfinishedPool.count),
                    unit: "条",
                    fact: fact,
                    relatedDates: uniqueDates(scope.unfinishedPool.flatMap { $0.unfinishedTraces.map(\.trace.date) })
                )
            )
            facts.append(fact)
        }

        if scope.taskPool.isEmpty == false {
            let fact = "任务池中有 \(scope.taskPool.count) 条尚未排期的任务。"
            evidence.append(
                AIEvidence(metric: "task_pool_count", value: Double(scope.taskPool.count), unit: "条", fact: fact)
            )
            facts.append(fact)
        }

        return LocalInsightReport(evidence: evidence, facts: facts)
    }

    private func uniqueTraceSnapshots(in scope: AIScopeSnapshot) -> [AITraceSnapshot] {
        var seen = Set<DayTraceID>()
        var traces: [AITraceSnapshot] = []

        for trace in scope.dayTodos.flatMap(\.traces) where seen.insert(trace.trace.id).inserted {
            traces.append(trace)
        }

        let unfinishedTraces = scope.unfinishedPool.flatMap { item in
            item.unfinishedTraces + (item.activeTrace.map { [$0] } ?? [])
        }
        for trace in unfinishedTraces where seen.insert(trace.trace.id).inserted {
            traces.append(trace)
        }

        for item in scope.completedPool {
            for trace in item.trajectory.traces {
                guard let definition = scope.completedPool.first(where: { $0.trace.definitionID == trace.definitionID })?.definition else {
                    continue
                }
                let snapshot = AITraceSnapshot(trace: trace, definition: definition, subtasks: [], subtaskProgress: emptyProgress)
                if seen.insert(trace.id).inserted {
                    traces.append(snapshot)
                }
            }
        }

        return traces.sorted {
            if $0.trace.date != $1.trace.date {
                return $0.trace.date < $1.trace.date
            }
            return $0.trace.createdAt < $1.trace.createdAt
        }
    }

    private var emptyProgress: SubtaskProgress {
        SubtaskProgress(total: 0, completed: 0, pending: 0, unfinished: 0, continued: 0, abandoned: 0)
    }

    private func uniqueDates(_ dates: [LocalDate]) -> [LocalDate] {
        var seen = Set<LocalDate>()
        var result: [LocalDate] = []

        for date in dates.sorted() where seen.insert(date).inserted {
            result.append(date)
        }

        return result
    }
}
