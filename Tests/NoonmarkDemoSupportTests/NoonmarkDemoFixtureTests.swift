import Foundation
import NoonmarkCore
@testable import NoonmarkDemoSupport
import Testing

@Suite("交互式演示基线")
struct NoonmarkDemoFixtureTests {
    private let anchorDate = LocalDate("2026-07-24")

    @Test("固定一年用户故事覆盖所有主要任务投影")
    func coversAnnualUserStory() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )

        #expect(fixture.storyDates.count == 365)
        #expect(fixture.storyDates.first == LocalDate("2025-07-25"))
        #expect(fixture.storyDates.last == anchorDate)
        #expect(fixture.report.fixtureProfile == "annual-v1")
        #expect(fixture.report.storyDayCount == 365)
        #expect(fixture.report.storyDateGapCount == 0)
        #expect(fixture.report.storyDuplicateDateCount == 0)
        #expect(fixture.report.storyDayWithOrdinaryTraceCount == 365)
        #expect(fixture.report.featureReplayDayCount == 12)
        #expect(fixture.report.featureReplayCoveredQuarterCount == 4)
        #expect(fixture.report.reviewedDayCount == 365)
        #expect(
            fixture.report.repeatedFeatureCounts.minimumUsageCount >= 12
        )
        #expect(
            fixture.report.minimumRepeatedFeatureUsageCount >= 12
        )
        #expect(fixture.engine.getDayTodo(date: anchorDate).traces.isEmpty == false)
        #expect(fixture.engine.taskPool().isEmpty == false)
        #expect(fixture.engine.futurePlans(today: anchorDate).isEmpty == false)
        #expect(fixture.engine.unfinishedPool().isEmpty == false)
        #expect(fixture.engine.completedPool().isEmpty == false)
        #expect(
            fixture.engine.taskPoolCount()
                == fixture.engine.taskPool().count
        )
        #expect(
            fixture.engine.unfinishedPoolCount()
                == fixture.engine.unfinishedPool().count
        )
        #expect(
            fixture.engine.completedTaskHierarchyCount()
                == fixture.engine.completedTaskHierarchies().count
        )
        let track = try #require(
            fixture.engine.taskCycleTracks(today: anchorDate).first {
                $0.title == "每日产品复盘"
            }
        )
        #expect(
            fixture.engine.taskCycleTrack(
                seriesID: track.id,
                today: anchorDate
            ) == track
        )
        #expect(track.days.count == 13)
        #expect(fixture.report.taskCycleSeriesCount == 12)
        #expect(fixture.report.taskCycleOccurrenceCount >= 500)
        #expect(fixture.report.classifiedTaskCycleSeriesCount == 2)
        #expect(
            fixture.report.taskCycleSeriesWithPlannedSubtasksCount >= 10
        )
        #expect(fixture.report.taskCyclePlanRevisionCount >= 8)
        #expect(fixture.report.taskCycleSkippedOccurrenceCount >= 3)
        #expect(fixture.report.taskCycleRescheduledOccurrenceCount >= 3)
        #expect(fixture.report.unstartedTaskCycleSeriesCount >= 3)
        #expect(
            fixture.report.taskCycleLifecycleCounts
                == NoonmarkDemoTaskCycleLifecycleCounts(
                    active: 3,
                    upcoming: 3,
                    ended: 3,
                    stopped: 3
                )
        )
        #expect(
            fixture.report.visibleRecurringFutureOccurrenceCount == 16
        )
        #expect(fixture.report.recurringCollectionLeakCount == 0)
        #expect(
            fixture.engine.taskCycleTracks(today: anchorDate).count == 12
        )
        #expect(fixture.engine.taskPool().allSatisfy {
            fixture.engine.isRecurringTaskChain($0.chain.id) == false
        })
        #expect(fixture.report.deletableCategoryBoundaryCount > 0)
        #expect(fixture.report.taskWithCollapsibleTrailCount > 0)
        #expect(fixture.report.continuableUnfinishedTaskCount > 0)
        #expect(
            fixture.report.openParentWithCompletedChildrenCount > 0
        )
        #expect(
            fixture.report
                .completedParentWithCompletedChildrenCount > 0
        )
        #expect(
            track.days.first {
                $0.date == LocalDate("2026-07-26")
            }?.state == .skipped
        )
        let movedFutureTarget = try #require(
            track.days.first {
                $0.futurePlanTarget?.date != nil
                    && $0.futurePlanTarget?.date != $0.date
            }?.futurePlanTarget
        )
        #expect(movedFutureTarget.date == LocalDate("2026-07-28"))
        #expect(fixture.report.isComplete)
    }

    @Test("年度历史让每项普通任务能力至少真实重放十二次")
    func repeatsEveryOrdinaryTaskFeature() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let counts = fixture.report.repeatedFeatureCounts

        #expect(counts.poolTaskCreation >= 12)
        #expect(counts.poolTaskTextEditing >= 12)
        #expect(counts.taskTitleEditing >= 12)
        #expect(counts.taskDescriptionEditing >= 12)
        #expect(counts.noteLifecycle >= 12)
        #expect(counts.plannedSubtaskEditing >= 12)
        #expect(counts.scheduling >= 12)
        #expect(counts.priorityReordering >= 12)
        #expect(counts.pinLifecycle >= 12)
        #expect(counts.manualProgressEditing >= 12)
        #expect(counts.taskCompletion >= 12)
        #expect(counts.taskCompletionUndo >= 12)
        #expect(counts.unfinishedContinuation >= 12)
        #expect(counts.deferral >= 12)
        #expect(counts.deferralWithdrawal >= 12)
        #expect(counts.taskChange >= 12)
        #expect(counts.returnToPool >= 12)
        #expect(counts.abandonment >= 12)
        #expect(counts.reactivation >= 12)
        #expect(counts.copying >= 12)
        #expect(counts.futureRescheduling >= 12)
        #expect(counts.subtaskCreation >= 12)
        #expect(counts.subtaskTextEditing >= 12)
        #expect(counts.subtaskDifficultyEditing >= 12)
        #expect(counts.subtaskCompletion >= 12)
        #expect(counts.subtaskCompletionUndo >= 12)
        #expect(counts.subtaskAbandonment >= 12)
        #expect(counts.subtaskDeletion >= 12)
        #expect(counts.classification >= 12)
    }

    @Test("基线包含真实边界状态而非仅有页面占位数据")
    func coversBoundaryStates() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let engine = fixture.engine
        let todayTraces = engine.getDayTodo(date: anchorDate).traces

        #expect(todayTraces.filter { $0.pinOrder != nil }.count >= 2)
        #expect(
            todayTraces.contains {
                $0.status == .deferred
                    && engine.canWithdrawDeferral(
                        sourceTraceID: $0.id,
                        today: anchorDate
                    )
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .returnedToPool
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .changed
            }
        )
        #expect(
            engine.snapshot().traces.contains {
                $0.status == .abandoned
            }
        )
        #expect(
            Set(engine.snapshot().subtasks.map(\.status))
                .isSuperset(of: [.pending, .completed, .unfinished, .abandoned])
        )
        #expect(
            engine.taskPool().contains {
                $0.definition.plannedSubtasks.count >= 3
                    && $0.chain.activeNoteEntries.isEmpty == false
            }
        )
        #expect(
            engine.snapshot().days.filter {
                $0.reviewSummary?.isEmpty == false
            }.count >= 6
        )
        let completedItems = engine.completedPool()
        #expect(
            completedItems.count {
                $0.trajectory.traces.count == 1
                    && engine.chains[
                        $0.trace.chainID
                    ]?.cycleMembership == nil
            } >= 365
        )
        #expect(
            completedItems.allSatisfy {
                engine.chains[$0.trace.chainID]?
                    .cycleMembership == nil
            }
        )
        #expect(
            completedItems.count {
                $0.trajectory.traces.count >= 2
            } >= 24
        )
        let ordinaryHierarchies =
            engine.completedTaskHierarchies().filter {
                $0.chain.cycleMembership == nil
            }
        #expect(
            ordinaryHierarchies.contains {
                $0.parentCompletion == nil
                    && $0.completedChildren.count == 1
            }
        )
        #expect(
            ordinaryHierarchies.contains {
                $0.parentCompletion != nil
                    && $0.completedChildren.count == 3
            }
        )
    }

    @Test("跨冬夏令时仍按纽约自然日连续生成")
    func preservesCivilDatesAcrossDST() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(
            TimeZone(identifier: "America/New_York")
        )
        let snapshot = fixture.engine.snapshot()

        for date in [
            LocalDate("2025-11-02"),
            LocalDate("2026-03-08")
        ] {
            let trace = try #require(
                snapshot.traces.first {
                    $0.date == date
                        && fixture.engine.chains[$0.chainID]?
                        .cycleMembership == nil
                        && calendar.component(
                            .hour,
                            from: $0.createdAt
                        ) == 8
                }
            )
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: trace.createdAt
            )
            #expect(components.year == date.year)
            #expect(components.month == date.month)
            #expect(components.day == date.day)
        }
    }

    @Test("基线包含跨天、归类、编辑、置顶与回收站恢复的真实想法时间线")
    func coversIdeaCaptureTimeline() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let engine = fixture.engine
        let timeline = engine.ideaTimeline()

        #expect(timeline.count == 7)
        #expect(engine.snapshot().ideas.count == 9)
        #expect(engine.ideaTimelineByDay().count >= 3)
        #expect(timeline.contains { $0.labelIDs.isEmpty == false })
        #expect(timeline.contains { $0.categoryID != nil })
        #expect(timeline.contains { $0.updatedAt > $0.createdAt })
        let pinned = engine.pinnedIdeas()
        #expect(pinned.count == 1)
        #expect(pinned.allSatisfy { $0.pinnedAt != nil })
        let pinnedIDs = Set(pinned.map(\.id))
        #expect(timeline.allSatisfy { pinnedIDs.contains($0.id) == false })
        let tombstoned = engine.snapshot().ideas.filter { $0.isDeleted }
        #expect(tombstoned.count == 1)
        #expect(engine.ideaTrash().count == 1)
        let tombstonedIDs = Set(tombstoned.map(\.id))
        #expect(timeline.allSatisfy { tombstonedIDs.contains($0.id) == false })
        #expect(timeline.contains {
            $0.body == "数据口径注释确认由周报模板统一维护，恢复这条留作月底跟进提醒。"
                && $0.updatedAt > $0.createdAt
                && $0.deletedAt == nil
        })
        #expect(fixture.report.ideaCount == 7)
        #expect(fixture.report.ideaDayCount == 6)
        #expect(fixture.report.labeledIdeaCount == 4)
        #expect(fixture.report.categorizedIdeaCount == 2)
        #expect(fixture.report.editedIdeaCount == 3)
        #expect(fixture.report.tombstonedIdeaCount == 1)
        #expect(fixture.report.ideaTimelineTombstoneLeakCount == 0)
        #expect(fixture.report.pinnedIdeaCount == 1)
        #expect(fixture.report.restoredIdeaCount == 1)
        #expect(fixture.report.isComplete)
    }

    @Test("相同锚点生成相同语义覆盖清单")
    func producesDeterministicSemanticReport() throws {
        let first = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )
        let second = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate
        )

        #expect(first.report == second.report)
    }
}
