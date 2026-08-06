import Foundation
import NoonmarkCore
@testable import NoonmarkDemoSupport
import Testing

@Suite("英文演示故事变体")
struct NoonmarkDemoEnglishStoryTests {
    private let anchorDate = LocalDate("2026-07-24")

    @Test("英文故事与中文故事保持相同的实体覆盖计数")
    func matchesChineseCoverageCounts() throws {
        let chinese = try NoonmarkDemoFixture.make(anchorDate: anchorDate)
        let english = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate,
            language: .english
        )

        #expect(english.report == chinese.report)
        #expect(
            english.report.taskCycleSeriesCount
                == chinese.report.taskCycleSeriesCount
        )
        #expect(
            english.report.taskCycleOccurrenceCount
                == chinese.report.taskCycleOccurrenceCount
        )
        #expect(english.report.ideaCount == chinese.report.ideaCount)
        #expect(
            english.report.reviewedDayCount
                == chinese.report.reviewedDayCount
        )
        #expect(
            english.report.categoryCount == chinese.report.categoryCount
        )
        #expect(english.report.labelCount == chinese.report.labelCount)
        #expect(english.report.isComplete)
    }

    @Test("英文故事使用英文重复计划标题、分组、标签与飞光正文")
    func usesEnglishVisibleCopy() throws {
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate,
            language: .english
        )
        let engine = fixture.engine
        let snapshot = engine.snapshot()

        let track = try #require(
            engine.taskCycleTracks(today: anchorDate).first {
                $0.title == "Daily product review"
            }
        )
        #expect(track.days.count == 13)
        #expect(
            snapshot.classifications.categories.values.contains {
                $0.name == "Engineering"
            }
        )
        #expect(
            snapshot.classifications.categories.values.contains {
                $0.name == "Research"
            }
        )
        #expect(
            snapshot.classifications.labels.values.contains {
                $0.name == "Release"
            }
        )
        #expect(snapshot.ideas.contains {
            $0.body
                == "Data-caliber notes stay in the weekly template; restored as a month-end reminder."
                && $0.updatedAt > $0.createdAt
                && $0.deletedAt == nil
        })
        #expect(engine.pinnedIdeas().count == 3)
    }

    @Test("英文飞光正文保持单行卡片长度")
    func keepsIdeaBodiesOnOneLine() throws {
        // 飞光时间线的演示验收要求置顶卡片全部渲染在可视区内；正文折行会加高
        // 卡片并把最旧的置顶卡片挤出视口。英文正文必须与中文一样保持单行。
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate,
            language: .english
        )
        let bodies = fixture.engine.snapshot().ideas.map(\.body)
        #expect(bodies.isEmpty == false)
        for body in bodies {
            #expect(body.count <= 88)
        }
    }

    @Test("英文文案表与英文故事数据不含 CJK 字符")
    func containsNoCJKCharacters() throws {
        let tableStrings = DemoStoryText.english.allProducedStrings
        #expect(tableStrings.count > 100)
        for value in tableStrings {
            #expect(value.containsCJKCharacters == false)
        }

        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: anchorDate,
            language: .english
        )
        let snapshot = fixture.engine.snapshot()
        var produced: [String] = []
        produced.append(contentsOf: snapshot.definitions.map(\.title))
        produced.append(
            contentsOf: snapshot.definitions.compactMap(\.descriptionText)
        )
        produced.append(
            contentsOf: snapshot.definitions.flatMap {
                $0.plannedSubtasks.map(\.title)
            }
        )
        produced.append(
            contentsOf: snapshot.chains.flatMap {
                $0.activeNoteEntries.map(\.body)
            }
        )
        produced.append(
            contentsOf: snapshot.subtasks.filter(\.isUserPresentable)
                .map(\.title)
        )
        produced.append(contentsOf: snapshot.ideas.map(\.body))
        produced.append(
            contentsOf: snapshot.classifications.categories.values
                .map(\.name)
        )
        produced.append(
            contentsOf: snapshot.classifications.labels.values.map(\.name)
        )
        produced.append(
            contentsOf: snapshot.days.compactMap(\.reviewSummary)
        )
        produced.append(
            contentsOf: snapshot.days.compactMap(\.reviewUnfinishedReason)
        )
        produced.append(
            contentsOf: snapshot.days.compactMap(\.reviewTomorrowNote)
        )
        #expect(produced.isEmpty == false)
        for value in produced {
            #expect(value.containsCJKCharacters == false)
        }
    }

    @Test("默认语言保持中文输出逐字不变")
    func defaultsToChinese() throws {
        let fixture = try NoonmarkDemoFixture.make(anchorDate: anchorDate)

        #expect(
            fixture.engine.taskCycleTracks(today: anchorDate).contains {
                $0.title == "每日产品复盘"
            }
        )
        #expect(
            fixture.engine.snapshot().classifications.categories.values
                .contains { $0.name == "工程" }
        )
        #expect(
            DemoStoryText.chinese.allProducedStrings.contains {
                $0.containsCJKCharacters
            }
        )
    }
}

extension DemoStoryText {
    /// 遍历文案表产出的全部字符串；closure 文案以多个代表入参采样。
    var allProducedStrings: [String] {
        var collected: [String] = []
        collectProducedStrings(
            from: Mirror(reflecting: self),
            into: &collected
        )
        return collected
    }

    private func collectProducedStrings(
        from mirror: Mirror,
        into collected: inout [String]
    ) {
        for child in mirror.children {
            if let string = child.value as? String {
                collected.append(string)
            } else if let template = child.value as? (Int) -> String {
                for input in [1, 7, 12, 365] {
                    collected.append(template(input))
                }
            } else {
                collectProducedStrings(
                    from: Mirror(reflecting: child.value),
                    into: &collected
                )
            }
        }
    }
}

extension String {
    var containsCJKCharacters: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000 ... 0x303F,
                 0x3400 ... 0x4DBF,
                 0x4E00 ... 0x9FFF,
                 0xF900 ... 0xFAFF,
                 0xFF00 ... 0xFF65:
                true
            default:
                false
            }
        }
    }
}
