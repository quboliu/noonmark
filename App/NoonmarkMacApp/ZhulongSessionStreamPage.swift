import NoonmarkZhulong
import SwiftUI

struct ZhulongSessionStreamPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @State private var expandedSections: Set<ZhulongStreamSection> = []
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
                    variantMenu
                    if workspace.selectedSession?.workspaceStatus == .paused {
                        HeaderButton("继续") { workspace.resumeCurrentSession() }
                    } else {
                        HeaderButton("暂停") { workspace.pauseCurrentSession() }
                    }
                }
            }

            statusBand

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
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityIdentifier("zhulong-session-stream")
                .onChange(of: records.count) {
                    guard let currentRecordID else { return }
                    withAnimation(.easeInOut(duration: 0.32)) {
                        proxy.scrollTo(currentRecordID, anchor: .center)
                    }
                }
                .onChange(of: workspace.variant) {
                    guard let currentRecordID else { return }
                    proxy.scrollTo(currentRecordID, anchor: .center)
                }
            }
        }
        .background(Theme.background)
        .onAppear {
            if expandedSections.isEmpty, let section = records.last?.section {
                expandedSections.insert(section)
            }
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

    private var variantMenu: some View {
        Menu {
            ForEach(ZhulongStreamVariant.allCases) { variant in
                Button {
                    workspace.variant = variant
                } label: {
                    Label(
                        "\(variant.shortName) · \(variant.title) — \(variant.purpose)",
                        systemImage: workspace.variant == variant ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("视图 · \(workspace.variant.title)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .hoverSurface(
                cornerRadius: 7,
                idleFill: Theme.controlFill,
                hoverFill: Theme.listRowHover,
                idleStroke: Theme.line.opacity(0.72),
                hoverStroke: Theme.line2.opacity(0.72)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("zhulong-stream-variant-menu")
    }

    private var statusBand: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(workspace.selectedSessionStatus)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("同一日志 · 仅追加 · \(records.count) 条记录")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Spacer()
            Text("当前视图不会改变授权或会话 head")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 24)
        .frame(height: 30)
        .background(Theme.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .overlay(alignment: .top) { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1) }
    }

    @ViewBuilder
    private var streamContent: some View {
        switch workspace.variant {
        case .dossier:
            dossierView
        case .chapters:
            chapterView
        case .weave:
            weaveView
        }
    }

    private var dossierView: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                HStack(alignment: .top, spacing: 10) {
                    dossierSpine(record: record, isLast: index == records.count - 1)
                    streamCard(record, isCurrent: record.id == currentRecordID)
                    Text(shortTime(record.occurredAt))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                        .frame(width: 42, alignment: .trailing)
                        .padding(.top, 11)
                }
                .id(record.id)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-dossier")
    }

    private var chapterView: some View {
        VStack(spacing: 0) {
            ForEach(activeSections) { section in
                let sectionRecords = records.filter { $0.section == section }
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedSections.contains(section) },
                        set: { expanded in
                            if expanded {
                                expandedSections.insert(section)
                            } else {
                                expandedSections.remove(section)
                            }
                        }
                    )
                ) {
                    VStack(spacing: 8) {
                        ForEach(sectionRecords) { record in
                            streamCard(record, isCurrent: record.id == currentRecordID)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                } label: {
                    chapterHeader(section, records: sectionRecords)
                }
                .tint(Theme.text3)
                if section != activeSections.last {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-chapters")
    }

    private var weaveView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("烛龙 · 分析、选项与执行")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("你 · 决定与授权")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.panel2)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(spacing: 9) {
                ForEach(records) { record in
                    weaveRow(record)
                        .id(record.id)
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-weave")
    }

    @ViewBuilder
    private var currentAction: some View {
        if let session = workspace.selectedSession, isScopeReviewActive {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("共同决策点 · 确认本次范围")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    StatusPill(text: "等待你", color: Theme.accent)
                }
                Text("烛龙只读取下列范围形成可审查结果；规划委托、Todo 写入和长期记忆仍分别确认。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                HStack(spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 23)
                            .background(Capsule().fill(Theme.chip))
                            .overlay(Capsule().stroke(Theme.line))
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(text: "等待你", color: Theme.warn)
            }
            Text(gate.draft.prompt)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text1)
            Text(gate.draft.reason)
                .font(.system(size: 11))
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.text1)
                            Text(option.impact)
                                .font(.system(size: 10.5))
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
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.24)))
    }

    private func decisionGateRevisionAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("将新决定写入规划简报")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text("决策门已经处置，但旧简报仍不具备执行权。建立新版本后必须重新审查和单次委托。")
                .font(.system(size: 11))
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.dailyReviewReceipts.isEmpty ? "待你确认" : "已保存",
                    color: session.dailyReviewReceipts.isEmpty ? Theme.warn : Theme.ok
                )
            }
            if let suggestion = latestProviderSuggestion(session) {
                Text("Provider 建议：\(suggestion)")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                SmallActionButton("确认并保存复盘", tone: .accent) {
                    store.confirmAndSaveCurrentZhulongDailyReview()
                }
                .accessibilityIdentifier("zhulong-confirm-save-daily-review")
            }
            Text("复盘文本和 Todo 变更分开确认；保存不会改写已锁定的日轨迹。")
                .font(.system(size: 10.5))
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
                    .font(.system(size: 12.5, weight: .semibold))
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.reviewedPlanningBrief?.id == brief.id ? "已审查" : "待审查",
                    color: session.reviewedPlanningBrief?.id == brief.id ? Theme.ok : Theme.warn
                )
            }
            MarkdownText(brief.goal)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text1)
            VStack(alignment: .leading, spacing: 4) {
                Text("成功标准")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(brief.successCriteria, id: \.self) { criterion in
                    MarkdownText("- \(criterion)")
                        .font(.system(size: 11))
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
                .font(.system(size: 10.5))
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.currentTodoDiff == nil ? "待形成 Todo diff" : "Todo diff 待确认",
                    color: Theme.warn
                )
            }
            MarkdownText(artifact.proposal.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            ForEach(artifact.proposal.stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(stage.objective)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    if stage.deliverables.isEmpty == false {
                        Text("交付物：\(stage.deliverables.joined(separator: "；"))")
                            .font(.system(size: 10.5))
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
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    ForEach(diff.items, id: \.id) { item in
                        Label(todoOperationLabel(item.operation), systemImage: "plus.circle")
                            .font(.system(size: 10.8))
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
                .font(.system(size: 10.5))
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

    private var activeSections: [ZhulongStreamSection] {
        ZhulongStreamSection.allCases.filter { section in
            records.contains { $0.section == section }
        }
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

    private func dossierSpine(record: ZhulongStreamRecord, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(actorColor(record.actor).opacity(0.14))
                Text(actorMark(record.actor))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(actorColor(record.actor))
            }
            .frame(width: 20, height: 20)
            if isLast == false {
                Rectangle().fill(Theme.line2.opacity(0.65)).frame(width: 1, height: 42)
            }
        }
        .frame(width: 24)
        .padding(.top, 9)
    }

    private func chapterHeader(
        _ section: ZhulongStreamSection,
        records: [ZhulongStreamRecord]
    ) -> some View {
        HStack(spacing: 11) {
            Text(String(format: "%02d", (activeSections.firstIndex(of: section) ?? 0) + 1))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(records.last?.title ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(records.count) 条")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    @ViewBuilder
    private func weaveRow(_ record: ZhulongStreamRecord) -> some View {
        if record.isBoundary || record.actor == .system {
            streamCard(record, isCurrent: record.id == currentRecordID)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if record.actor == .zhulong {
                    streamCard(record, isCurrent: record.id == currentRecordID)
                    causalNode(record)
                    Color.clear.frame(maxWidth: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                    causalNode(record)
                    streamCard(record, isCurrent: record.id == currentRecordID)
                }
            }
        }
    }

    private func causalNode(_ record: ZhulongStreamRecord) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line2).frame(width: 1, height: 8)
            Circle().fill(actorColor(record.actor)).frame(width: 7, height: 7)
            Rectangle().fill(Theme.line2).frame(width: 1, height: 34)
        }
        .frame(width: 20)
    }

    private func streamCard(_ record: ZhulongStreamRecord, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(record.eyebrow)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(record.isInvalidation ? Theme.warn : actorColor(record.actor))
                    .tracking(0.35)
                Spacer()
                Text(shortTime(record.occurredAt))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            Text(record.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
            if let body = record.body {
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                isCurrent
                    ? Theme.accentSoft.opacity(0.62)
                    : record.actor == .zhulong ? Theme.navZhulong.opacity(0.035) : Theme.panel2
            )
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Theme.accent).frame(width: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Theme.accent.opacity(0.24) : Theme.line)
        )
        .opacity(record.isInvalidation ? 0.62 : 1)
    }

    private func actorColor(_ actor: ZhulongStreamActor) -> Color {
        switch actor {
        case .user: Theme.accent
        case .zhulong: Theme.navZhulong
        case .system: Theme.text3
        }
    }

    private func actorMark(_ actor: ZhulongStreamActor) -> String {
        switch actor {
        case .user: "你"
        case .zhulong: "烛"
        case .system: "系"
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
        case .taskClassifications: "分类与标签"
        }
    }
}
