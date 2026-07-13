import NoonmarkZhulong
import SwiftUI

struct ZhulongSessionStreamPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @State private var entryText = ""
    @State private var briefGoal = ""
    @State private var briefSuccessCriteria = ""
    @State private var briefHardConstraints = ""
    @State private var dailyReviewSummary = ""
    @State private var dailyReviewTomorrow = ""
    @State private var decisionSupplement = ""
    @State private var todoDiffBeingEdited: ZhulongTodoDiffDraft?

    private var records: [ZhulongStreamRecord] { workspace.records }
    private var currentRecordID: String? { records.last?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "烛龙",
                subtitle: workspace.selectedSession?.primaryIntent,
                badge: workspace.selectedSessionStatus,
                badgeColor: statusColor
            ) {
                HStack(spacing: 7) {
                    HeaderButton("全部会话") { workspace.showHome() }
                        .accessibilityIdentifier("zhulong-session-show-home")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "zhulong-session-show-home",
                                verificationText: "全部会话"
                            )
                        }
                    if workspace.selectedSession?.workspaceStatus == .paused {
                        HeaderButton("继续") { workspace.resumeCurrentSession() }
                    } else {
                        HeaderButton("暂停") { workspace.pauseCurrentSession() }
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        streamContent
                        currentAction
                        entryComposer
                        if let message = workspace.statusMessage {
                            Notice(text: message, tone: .locked)
                        }
                    }
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityIdentifier("zhulong-session-stream")
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-session-stream",
                        verificationText: "烛龙会话流"
                    )
                }
                .onChange(of: records.count) {
                    guard let currentRecordID else { return }
                    withAnimation(.easeInOut(duration: 0.32)) {
                        proxy.scrollTo(currentRecordID, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier(
            "zhulong-session-purpose-\(workspace.selectedSession?.purpose.rawValue ?? "unknown")"
        )
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-session-purpose-\(workspace.selectedSession?.purpose.rawValue ?? "unknown")",
                verificationText: workspace.selectedSession?.primaryIntent ?? "烛龙会话"
            )
        }
        .onAppear {
            if briefGoal.isEmpty {
                briefGoal = workspace.selectedSession?.primaryIntent ?? ""
            }
            if dailyReviewSummary.isEmpty {
                dailyReviewSummary = store.engine.days[store.today]?.reviewSummary ?? ""
            }
            if dailyReviewTomorrow.isEmpty {
                dailyReviewTomorrow = store.engine.days[store.today]?.reviewTomorrowNote ?? ""
            }
            openTodoDiffEditorForE2EIfReady()
        }
        .onChange(of: workspace.selectedSession?.currentTodoDiff?.id.rawValue) {
            openTodoDiffEditorForE2EIfReady()
        }
        .sheet(
            isPresented: Binding(
                get: { todoDiffBeingEdited != nil },
                set: { if $0 == false { todoDiffBeingEdited = nil } }
            )
        ) {
            if let diff = todoDiffBeingEdited {
                ZhulongTodoDiffEditor(diff: diff) { items in
                    workspace.reviseCurrentTodoDiff(items: items)
                }
            }
        }
    }

    private var streamContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("会话轨迹")
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)

            ForEach(records) { record in
                streamRow(record)
                    .id(record.id)
                if record.id != currentRecordID {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                        .padding(.leading, 82)
                }
            }
        }
        .accessibilityIdentifier("zhulong-session-timeline")
    }

    @ViewBuilder
    private var currentAction: some View {
        if let session = workspace.selectedSession, isScopeReviewActive {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("共同决策点 · 确认本次范围")
                        .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    StatusPill(text: "等待你", color: Theme.accent)
                }
                Text("烛龙只读取下列范围形成可审查结果；规划委托、Todo 写入和长期记忆仍分别确认。")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                HStack(spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.noonmarkSystem(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 23)
                            .background(Capsule().fill(Theme.chip))
                            .overlay(Capsule().stroke(Theme.line))
                            .accessibilityIdentifier("zhulong-session-scope-\(scope.rawValue)")
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "zhulong-session-scope-\(scope.rawValue)",
                                    verificationText: scopeLabel(scope)
                                )
                            }
                    }
                }
                SmallActionButton("仅在本次会话使用", tone: .accent) {
                    store.authorizeCurrentZhulongWorkspaceSession()
                }
                .accessibilityIdentifier("zhulong-authorize-scope")
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.55)))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.25)))
        } else if workspace.selectedSession?.phase == .readyForProvider {
            if let session = decisionRevisionSession {
                decisionGateRevisionAction(session)
            } else if let context = readyPlanningBriefContext {
                planningBriefAction(context.brief, session: context.session)
            } else if let session = readyDailyReviewSession {
                dailyReviewAction(session)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Notice(
                        text: store.zhulongProviderDraft.enabled
                            ? "范围已经确认。运行前将按右侧披露的范围构造本次 Provider 请求。"
                            : "范围已经确认。没有可用 Provider 时保持本地模式，不会用固定模板冒充模型结果。",
                        tone: .future
                    )
                    if store.zhulongProviderDraft.enabled {
                        SmallActionButton("开始生成", tone: .accent) {
                            store.runCurrentZhulongProvider()
                        }
                        .accessibilityIdentifier("zhulong-run-provider")
                    } else if workspace.selectedSession?.dailyCloseSnapshots.contains(where: { $0.date == store.today }) == false {
                        SmallActionButton("捕获今日事实") {
                            store.captureCurrentZhulongDailyClose()
                        }
                        .accessibilityIdentifier("zhulong-capture-daily-close")
                    }
                }
            }
        } else if let session = workspace.selectedSession, session.phase == .draftReview {
            if isDailyReviewSession(session) {
                dailyReviewAction(session)
            } else {
                draftReviewAction(session)
            }
        } else if let gate = workspace.selectedSession?.currentDecisionGate {
            decisionGateAction(gate)
        }
    }

    private func decisionGateAction(_ gate: ZhulongDecisionGate) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("共同决策点")
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(text: "等待你", color: Theme.warn)
            }
            Text(gate.draft.prompt)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text1)
            Text(gate.draft.reason)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            ForEach(gate.draft.options, id: \.id) { option in
                Button {
                    workspace.resolveCurrentDecisionGate(
                        selectedOptionID: option.id,
                        supplementalDecision: optionalText(decisionSupplement)
                    )
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.noonmarkSystem(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.text1)
                            Text(option.impact)
                                .font(.noonmarkSystem(size: 10.5))
                                .foregroundStyle(Theme.text3)
                                .lineSpacing(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("zhulong-decision-option-\(option.id)")
            }
            MarkdownEditor(
                text: $decisionSupplement,
                placeholder: "补充你的取舍依据，可留空",
                style: .body
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            Text("选择后会追加一条用户决定；旧简报和旧委托随即失效。")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.24)))
    }

    private func decisionGateRevisionAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("将新决定写入规划简报")
                .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text("决策门已经处置，但旧简报仍不具备执行权。建立新版本后必须重新审查和单次委托。")
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            SmallActionButton("建立包含新决定的简报版本", tone: .accent) {
                workspace.incorporateDecisionGateResolution()
            }
            .accessibilityIdentifier("zhulong-revise-brief-after-decision")
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func dailyReviewAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("每日收尾复盘")
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.dailyReviewReceipts.isEmpty ? "待你确认" : "已保存",
                    color: session.dailyReviewReceipts.isEmpty ? Theme.warn : Theme.ok
                )
            }
            if let suggestion = latestProviderSuggestion(session) {
                Text("Provider 建议：\(suggestion)")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            if session.dailyReviewReceipts.isEmpty == false {
                Notice(text: "复盘已保存到当天记录；Todo 处置仍使用独立 Todo diff。", tone: .future)
            } else if session.dailyReviewDrafts.isEmpty {
                MarkdownEditor(text: $dailyReviewSummary, placeholder: "今天发生了什么？", style: .body)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(text: $dailyReviewTomorrow, placeholder: "明天开始前提醒自己什么？", style: .body)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                SmallActionButton("形成复盘草稿", tone: .accent) {
                    store.publishCurrentZhulongDailyReview(
                        summary: optionalText(dailyReviewSummary),
                        tomorrowNote: optionalText(dailyReviewTomorrow)
                    )
                }
                .disabled(optionalText(dailyReviewSummary) == nil && optionalText(dailyReviewTomorrow) == nil)
                .accessibilityIdentifier("zhulong-publish-daily-review")
            } else {
                let draft = session.dailyReviewDrafts.last
                MarkdownText(draft?.summary ?? draft?.tomorrowNote ?? "")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                SmallActionButton("确认并保存复盘", tone: .accent) {
                    store.confirmAndSaveCurrentZhulongDailyReview()
                }
                .accessibilityIdentifier("zhulong-confirm-save-daily-review")
            }
            Text("复盘文本和 Todo 变更分开确认；保存不会改写已锁定的日轨迹。")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func isDailyReviewSession(_ session: ZhulongSession) -> Bool {
        store.zhulongTask(for: session) == .dailyReview
    }

    private var readyDailyReviewSession: ZhulongSession? {
        guard let session = workspace.selectedSession,
              isDailyReviewSession(session),
              session.dailyCloseSnapshots.isEmpty == false
        else { return nil }
        return session
    }

    private var decisionRevisionSession: ZhulongSession? {
        guard let session = workspace.selectedSession,
              session.currentBriefRequiresDecisionGateRevision
        else { return nil }
        return session
    }

    private var readyPlanningBriefContext: (
        session: ZhulongSession,
        brief: ZhulongPlanningBrief
    )? {
        guard let session = workspace.selectedSession,
              let brief = session.currentPlanningBrief
        else { return nil }
        return (session, brief)
    }

    private func latestProviderSuggestion(_ session: ZhulongSession) -> String? {
        session.providerSends.reversed().compactMap(\.response?.content).first
    }

    private func optionalText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    @ViewBuilder
    private func draftReviewAction(_ session: ZhulongSession) -> some View {
        if let artifact = session.effectivePlanArtifact {
            planArtifactAction(artifact, session: session)
        } else if let brief = session.currentPlanningBrief {
            planningBriefAction(brief, session: session)
        } else {
            VStack(alignment: .leading, spacing: 11) {
                Text("把初步结果收束为规划简报")
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                MarkdownEditor(text: $briefGoal, placeholder: "目标", style: .compact)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(text: $briefSuccessCriteria, placeholder: "成功标准，每行一项", style: .body)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(text: $briefHardConstraints, placeholder: "硬约束，可留空；每行一项", style: .body)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                SmallActionButton("保存规划简报", tone: .accent) {
                    publishPlanningBrief(for: session)
                }
                .disabled(normalizedLines(briefSuccessCriteria).isEmpty)
                .accessibilityIdentifier("zhulong-publish-planning-brief")
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }

    private func planningBriefAction(
        _ brief: ZhulongPlanningBrief,
        session: ZhulongSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("规划简报 v\(brief.version)")
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.reviewedPlanningBrief?.id == brief.id ? "已审查" : "待审查",
                    color: session.reviewedPlanningBrief?.id == brief.id ? Theme.ok : Theme.warn
                )
            }
            MarkdownText(brief.goal)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text1)
            VStack(alignment: .leading, spacing: 4) {
                Text("成功标准")
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(brief.successCriteria, id: \.self) { criterion in
                    MarkdownText("- \(criterion)")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text2)
                }
            }
            if session.reviewedPlanningBrief?.id != brief.id {
                SmallActionButton("确认简报内容", tone: .accent) {
                    workspace.reviewCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-review-planning-brief")
            } else if session.activePlanningDelegation == nil {
                SmallActionButton("单次委托规划", tone: .accent) {
                    workspace.delegateCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-delegate-planning")
            } else if store.zhulongProviderDraft.enabled {
                SmallActionButton("运行本次规划", tone: .accent) {
                    store.runCurrentZhulongPlanningProvider()
                }
                .accessibilityIdentifier("zhulong-run-planning-provider")
            } else {
                Notice(text: "规划委托已记录；配置 Provider 前不会生成模型规划。", tone: .future)
            }
            Text("规划委托不包含 Todo 写入；后续 Todo diff 仍需单独批量确认。")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func planArtifactAction(
        _ artifact: ZhulongPlanArtifact,
        session: ZhulongSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("规划产物 v\(artifact.version)")
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.currentTodoDiff == nil ? "待形成 Todo diff" : "Todo diff 待确认",
                    color: Theme.warn
                )
            }
            MarkdownText(artifact.proposal.summary)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            ForEach(artifact.proposal.stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage.title)
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(stage.objective)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    if stage.deliverables.isEmpty == false {
                        Text("交付物：\(stage.deliverables.joined(separator: "；"))")
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            if let diff = session.currentTodoDiff {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Todo 变更 diff v\(diff.version) · \(diff.items.count) 项")
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    ForEach(diff.items, id: \.id) { item in
                        Label(todoOperationLabel(item.operation), systemImage: "plus.circle")
                            .font(.noonmarkSystem(size: 10.8))
                            .foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    SmallActionButton("审查与修订") {
                        todoDiffBeingEdited = diff
                    }
                    .disabled(workspace.hasActiveTodoAuthorization)
                    .accessibilityIdentifier("zhulong-edit-todo-diff")
                    SmallActionButton("批量确认并原子应用", tone: .accent) {
                        store.confirmAndApplyCurrentZhulongTodoDiff()
                    }
                    .accessibilityIdentifier("zhulong-confirm-apply-todo-diff")
                }
            } else {
                SmallActionButton("形成可审查 Todo diff", tone: .accent) {
                    store.publishCurrentZhulongTodoDiff()
                }
                .accessibilityIdentifier("zhulong-publish-todo-diff")
            }
            Text("近期交付物先进入任务池；确认前不会写入，整批应用要么全部成功，要么全部回滚。")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func todoOperationLabel(_ operation: ZhulongTodoDiffOperation) -> String {
        switch operation {
        case let .createTask(title, _, _, _, targetDate):
            targetDate.map { "创建任务“\(title)”并排期到 \($0)" } ?? "创建任务池任务“\(title)”"
        case let .addSubtask(_, title, _): "添加子任务“\(title)”"
        case let .scheduleFromPool(_, targetDate): "从任务池排期到 \(targetDate)"
        case let .continueTrace(_, targetDate): "延续任务到 \(targetDate)"
        case .abandonChain: "废弃任务链"
        }
    }

    private func openTodoDiffEditorForE2EIfReady() {
        guard CommandLine.arguments.contains("--e2e-open-zhulong-todo-diff-editor"),
              todoDiffBeingEdited == nil,
              let diff = workspace.selectedSession?.currentTodoDiff
        else { return }
        todoDiffBeingEdited = diff
    }

    @ViewBuilder
    private var entryComposer: some View {
        if canComposeEntry {
            HStack(alignment: .top, spacing: 9) {
                MarkdownEditor(
                    text: $entryText,
                    placeholder: "追加说明或更正上下文……",
                    style: .compact,
                    showsSurface: false,
                    onCommit: appendEntry
                )
                    .accessibilityIdentifier("zhulong-session-entry")
                SmallActionButton("追加") { appendEntry() }
                    .disabled(entryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }

    private var canComposeEntry: Bool {
        guard let session = workspace.selectedSession else { return false }
        return session.workspaceStatus == .active &&
            session.phase != .providerRunning &&
            session.phase != .decisionGate
    }

    private func appendEntry() {
        let content = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else { return }
        workspace.appendToCurrentSession(
            author: .user,
            kind: workspace.selectedSession?.phase == .draftReview ? .answer : .statement,
            content: content
        )
        entryText = ""
    }

    private func publishPlanningBrief(for session: ZhulongSession) {
        do {
            let draft = try ZhulongPlanningBriefDraft(
                goal: briefGoal,
                successCriteria: normalizedLines(briefSuccessCriteria),
                hardConstraints: normalizedLines(briefHardConstraints),
                userDecisions: session.entries.filter { $0.kind == .decision }.map(\.content),
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview, .initialScheduling],
                assumptions: [],
                openQuestions: [],
                dataScopes: session.proposedScopes,
                sourceEntryIDs: Set(session.entries.filter { $0.correctsEntryID == nil }.map(\.id))
            )
            workspace.publishPlanningBrief(draft)
        } catch {
            workspace.reportUIError("无法保存规划简报：\(error.localizedDescription)")
        }
    }

    private func normalizedLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "；") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var isScopeReviewActive: Bool {
        workspace.selectedSession?.workspaceStatus == .active &&
            workspace.selectedSession?.phase == .scopeReview
    }

    private var statusColor: Color {
        switch workspace.selectedSession?.workspaceStatus {
        case .paused: Theme.warn
        case .archived: Theme.text3
        case .active, nil: Theme.accent
        }
    }

    private func streamRow(_ record: ZhulongStreamRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.eyebrow)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(record.isInvalidation ? Theme.warn : actorColor(record.actor))
                .frame(width: 60, alignment: .trailing)
                .padding(.top, 1)
            streamCard(record)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .background(record.id == currentRecordID ? Theme.accentSoft.opacity(0.34) : Color.clear)
    }

    private func streamCard(_ record: ZhulongStreamRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(record.title)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
                Spacer()
                Text(shortTime(record.occurredAt))
                    .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            if let body = record.body {
                Text(body)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(record.isInvalidation ? 0.62 : 1)
    }

    private func actorColor(_ actor: ZhulongStreamActor) -> Color {
        switch actor {
        case .user: Theme.accent
        case .zhulong: Theme.navZhulong
        case .system: Theme.text3
        }
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        switch scope {
        case .currentDayTodo: "当前 Day Todo"
        case .taskPool: "任务池"
        case .unfinishedPool: "未完成池"
        case .completedPool: "已完成池"
        case .taskClassifications: "分组与标签"
        }
    }
}
