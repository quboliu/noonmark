import NoonmarkCore
@testable import NoonmarkDemoSupport
import Testing

@Suite("烛龙演示会话文案表")
struct NoonmarkDemoZhulongStoryTextTests {
    @Test("中文烛龙会话文案逐字保留现值")
    func chineseVerbatim() {
        let text = DemoStoryZhulongText.chinese

        #expect(
            text.poolAnalysis.primaryIntent
                == "分析当前任务池，找出需要澄清或安排的任务。"
        )
        #expect(
            text.poolAnalysis.findingConclusion("样例任务")
                == "「样例任务」的完成边界仍可更具体。"
        )
        #expect(
            text.submittedPlanning.primaryIntent
                == "帮我规划发布演示，并把结果安排进今天、任务池和未来计划。"
        )
        #expect(
            text.submittedPlanning.confirmedScopeSuffix == "（已确认范围）"
        )
        #expect(
            text.activePlanning.responseContent
                == "我拆成一个主任务和五个循序渐进的子任务，提交前都可以修改。"
        )
        #expect(
            text.dailyReview.tomorrowNote
                == "明天先确认法务依赖，再处理发布后的复盘安排。"
        )
        #expect(
            text.payload.scopeContent("taskPool") == "演示范围 taskPool 已授权"
        )
    }

    @Test("英文烛龙会话文案不含 CJK 字符")
    func englishContainsNoCJK() {
        let strings = DemoStoryZhulongText.english.allProducedStrings

        #expect(strings.count > 30)
        for value in strings {
            #expect(value.containsCJKCharacters == false)
        }
    }

    @Test("forLanguage 按语言返回对应实例")
    func forLanguageSwitch() {
        #expect(
            DemoStoryZhulongText.forLanguage(.chinese).payload.systemPrompt
                == DemoStoryZhulongText.chinese.payload.systemPrompt
        )
        #expect(
            DemoStoryZhulongText.forLanguage(.english).payload.systemPrompt
                == DemoStoryZhulongText.english.payload.systemPrompt
        )
    }
}

extension DemoStoryZhulongText {
    /// 遍历文案表产出的全部字符串；closure 文案以代表入参采样。
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
            } else if let template = child.value as? (String) -> String {
                collected.append(template("sample"))
            } else {
                collectProducedStrings(
                    from: Mirror(reflecting: child.value),
                    into: &collected
                )
            }
        }
    }
}
