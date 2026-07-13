import NoonmarkAI
import NoonmarkZhulong
import SwiftUI

struct ZhulongConvergedHome: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ZhulongWorkspaceRoot(workspace: store.zhulongWorkspace)
    }
}

private struct ZhulongWorkspaceRoot: View {
    @ObservedObject var workspace: ZhulongWorkspaceStore

    var body: some View {
        if workspace.selectedSession != nil {
            ZhulongSessionStreamPage(workspace: workspace)
        } else {
            ZhulongWorkspaceHome(workspace: workspace)
        }
    }
}

private struct ZhulongWorkspaceHome: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @FocusState private var intentIsFocused: Bool
    @State private var intent = ""
    @State private var hoveredWorkflowID: String?

    private var coreWorkflows: [ZhulongHomeWorkflow] {
        [
            ZhulongHomeWorkflow(
                id: "task-shaping",
                title: store.copy.zhulongTaskShapingTitle,
                detail: store.copy.zhulongTaskShapingDetail,
                intent: store.copy.zhulongTaskShapingIntent,
                task: .taskDecomposition,
                systemImage: "list.bullet.rectangle.portrait"
            ),
            ZhulongHomeWorkflow(
                id: "daily-close",
                title: store.copy.zhulongDailyCloseTitle,
                detail: store.copy.zhulongDailyCloseDetail,
                intent: store.copy.zhulongDailyCloseIntent,
                task: .dailyReview,
                systemImage: "sun.horizon"
            )
        ]
    }

    private var specialistAssistants: [ZhulongHomeWorkflow] {
        [
            ZhulongHomeWorkflow(
                id: "scheduling",
                title: store.copy.zhulongSchedulingTitle,
                detail: store.copy.zhulongSchedulingDetail,
                intent: store.copy.zhulongSchedulingIntent,
                task: .scheduling,
                systemImage: "calendar.badge.clock",
                badge: store.copy.zhulongSuggestionMode
            ),
            ZhulongHomeWorkflow(
                id: "classification",
                title: store.copy.zhulongClassificationTitle,
                detail: store.copy.zhulongClassificationDetail,
                intent: store.copy.zhulongClassificationIntent,
                task: .labelClassification,
                systemImage: "tag",
                badge: store.copy.zhulongSuggestionMode
            )
        ]
    }

    private var pendingCount: Int {
        workspace.sessions.filter { $0.workspaceStatus != .archived }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: store.copy.navZhulong,
                subtitle: "把模糊的事想清楚，把已经开始的事继续推进。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    intentComposer
                    workflowSection
                    pendingSection
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("zhulong-converged-home")
    }

    private var intentComposer: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text("你现在想推进什么？")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("先说结果，烛龙会在需要时再说明范围与授权。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
            }

            HStack(alignment: .center, spacing: 10) {
                MarkdownEditor(
                    text: $intent,
                    placeholder: "说说你现在想推进什么……",
                    style: .compact,
                    showsSurface: false,
                    onCommit: startIntent
                )
                    .focused($intentIsFocused)
                    .accessibilityIdentifier("zhulong-home-intent")

                Button(action: startIntent) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.text3 : Theme.accent)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .hoverSurface(
                    cornerRadius: 7,
                    idleFill: Theme.panel2,
                    hoverFill: Theme.accentSoft,
                    idleStroke: Theme.line,
                    hoverStroke: Theme.accent.opacity(0.28)
                )
                .accessibilityLabel("开始梳理")
                .accessibilityIdentifier("zhulong-home-submit")
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(intentIsFocused ? Theme.accent.opacity(0.42) : Theme.line, lineWidth: intentIsFocused ? 1.4 : 1)
            )
            .shadow(color: Theme.text1.opacity(0.035), radius: 14, y: 7)
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            workflowGroup(
                title: store.copy.zhulongFixedWorkflowsTitle,
                detail: store.copy.zhulongFixedWorkflowsDetail,
                workflows: coreWorkflows,
                isCore: true
            )
            workflowGroup(
                title: store.copy.zhulongSpecialistAssistantsTitle,
                detail: store.copy.zhulongSpecialistAssistantsDetail,
                workflows: specialistAssistants,
                isCore: false
            )
        }
        .accessibilityIdentifier("zhulong-home-workflows")
    }

    private func workflowGroup(
        title: String,
        detail: String,
        workflows: [ZhulongHomeWorkflow],
        isCore: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(workflows.enumerated()), id: \.element.id) { index, workflow in
                    workflowButton(workflow, isCore: isCore)
                    if index < workflows.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                            .overlay(Theme.line)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        }
    }

    private func workflowButton(_ workflow: ZhulongHomeWorkflow, isCore: Bool) -> some View {
        Button {
            startWorkflow(workflow)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isCore ? Theme.accentSoft : Theme.controlFill)
                    Image(systemName: workflow.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCore ? Theme.accent : Theme.text2)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(workflow.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        if let badge = workflow.badge {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.text3)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Capsule().fill(Theme.chip))
                        }
                    }
                    Text(workflow.detail)
                        .font(.system(size: 10.8))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hoveredWorkflowID == workflow.id ? Theme.accent : Theme.text3)
            }
            .padding(.horizontal, 11)
            .frame(height: isCore ? 58 : 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle().fill(
                    hoveredWorkflowID == workflow.id
                        ? (isCore ? Theme.accentSoft.opacity(0.45) : Theme.panel2)
                        : .clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredWorkflowID = isHovered ? workflow.id : nil
        }
        .accessibilityLabel(
            store.copy.zhulongWorkflowAccessibilityLabel(
                title: workflow.title,
                detail: workflow.detail
            )
        )
        .accessibilityIdentifier("zhulong-home-workflow-\(workflow.id)")
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("待你决定", count: pendingCount)

            if pendingCount == 0 {
                Text("现在没有等待你处理的事项。可以从上方开始一件新工作。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(workspace.sessions.filter { $0.workspaceStatus != .archived }, id: \.id) { session in
                    ZhulongWorkspaceSessionRow(session: session) {
                        workspace.selectSession(session.id)
                    }
                    Divider().overlay(Theme.line)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Spacer()
            Text("\(count) 项")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func startIntent() {
        let value = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }
        store.startZhulongWorkspaceSession(intent: value)
        intent = ""
        intentIsFocused = false
    }

    private func startWorkflow(_ workflow: ZhulongHomeWorkflow) {
        intentIsFocused = false
        store.startZhulongWorkspaceSession(intent: workflow.intent, task: workflow.task)
    }
}

private struct ZhulongWorkspaceSessionRow: View {
    let session: ZhulongSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.accentSoft)
                    Image(systemName: "text.append")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.primaryIntent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(sessionStatus)
                        .font(.system(size: 10.8))
                        .foregroundStyle(Theme.text2)
                    Text("下一步：继续同一条追加式会话流")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }

                Spacer(minLength: 10)
                Text("继续")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionStatus: String {
        if session.workspaceStatus == .paused { return "会话已暂停" }
        if session.workspaceStatus == .archived { return "会话已归档" }
        return switch session.phase {
        case .scopeReview: "等待你确认本次范围"
        case .readyForProvider: "范围已确认，可以继续推进"
        case .providerRunning: "Provider 正在运行"
        case .decisionGate: "等待你作出关键决定"
        case .draftReview: "草稿已形成，等待审查"
        }
    }
}

private struct ZhulongHomeWorkflow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let intent: String
    let task: ZhulongTask
    let systemImage: String
    let badge: String?

    init(
        id: String,
        title: String,
        detail: String,
        intent: String,
        task: ZhulongTask,
        systemImage: String,
        badge: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.intent = intent
        self.task = task
        self.systemImage = systemImage
        self.badge = badge
    }
}

private extension AppCopy {
    var zhulongFixedWorkflowsTitle: String { language == .chinese ? "固定工作流" : "Fixed workflows" }
    var zhulongFixedWorkflowsDetail: String {
        language == .chinese ? "流程、授权边界与落库方式固定" : "Fixed flow, authorization boundaries, and application"
    }

    var zhulongSpecialistAssistantsTitle: String { language == .chinese ? "专项助手" : "Specialist assistants" }
    var zhulongSpecialistAssistantsDetail: String {
        language == .chinese ? "进入有界会话，所有建议仍需确认" : "Bounded sessions; every suggestion still needs confirmation"
    }

    var zhulongSuggestionMode: String { language == .chinese ? "建议模式" : "Suggestion mode" }
    func zhulongWorkflowAccessibilityLabel(title: String, detail: String) -> String {
        language == .chinese
            ? "开始\(title)：\(detail)"
            : "Start \(title): \(detail)"
    }

    var zhulongTaskShapingTitle: String { language == .chinese ? "把模糊任务变成计划" : "Turn a fuzzy task into a plan" }
    var zhulongTaskShapingDetail: String {
        language == .chinese
            ? "澄清目标与约束，形成可审查的规划和 Todo diff"
            : "Clarify goals and constraints, then review the plan and Todo diff"
    }

    var zhulongTaskShapingIntent: String {
        language == .chinese ? "规划一个还很模糊的大任务" : "Plan a large task that is still fuzzy"
    }

    var zhulongDailyCloseTitle: String { language == .chinese ? "结束今天并安排明天" : "Close today and arrange tomorrow" }
    var zhulongDailyCloseDetail: String {
        language == .chinese
            ? "复盘今日事实，处置未完成任务并形成下一次承诺"
            : "Review today, resolve unfinished work, and form the next commitment"
    }

    var zhulongDailyCloseIntent: String {
        language == .chinese ? "结束今天并形成下一次可信承诺" : "Close today and form the next credible commitment"
    }

    var zhulongSchedulingTitle: String { language == .chinese ? "重新安排任务" : "Reschedule tasks" }
    var zhulongSchedulingDetail: String {
        language == .chinese
            ? "基于任务池与未完成任务提出可确认的排期建议"
            : "Suggest a reviewable schedule for pooled and unfinished tasks"
    }

    var zhulongSchedulingIntent: String {
        language == .chinese ? "给任务池和未完成任务重新排期" : "Reschedule tasks from the pool and unfinished work"
    }

    var zhulongClassificationTitle: String { language == .chinese ? "整理分组与标签" : "Organize groups and labels" }
    var zhulongClassificationDetail: String {
        language == .chinese
            ? "审查现有分类，并提出可确认的整理建议"
            : "Review current classifications and suggest confirmable changes"
    }

    var zhulongClassificationIntent: String {
        language == .chinese ? "整理任务的分组与标签分类" : "Organize task groups and label classifications"
    }
}

enum ZhulongHomeIntentResolver {
    static func task(for intent: String) -> ZhulongTask {
        let normalized = intent.lowercased()
        if containsAny(["收尾", "复盘", "回顾今天", "结束今天"], in: normalized) {
            return .dailyReview
        }
        if containsAny(["排期", "安排明天", "安排任务", "计划明天"], in: normalized) {
            return .scheduling
        }
        if containsAny(["标签", "分类", "归类"], in: normalized) {
            return .labelClassification
        }
        return .taskDecomposition
    }

    private static func containsAny(_ terms: [String], in value: String) -> Bool {
        terms.contains { value.contains($0) }
    }
}
