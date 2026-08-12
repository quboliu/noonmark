import NoonmarkAI
import SwiftUI
import NoonmarkZhulong

struct IOSZhulongPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var planningGoal = ""
    @State private var planningCriteria = ""
    @State private var planningConstraints = ""
    @State private var planningActivities: Set<ZhulongPlanningActivity> = [.taskDecomposition]

    private let taskOptions: [(ZhulongTask, String)] = [
        (.dailyReview, "每日复盘"),
        (.habitInsight, "习惯洞察"),
        (.taskDecomposition, "任务拆解"),
        (.scheduling, "排程协助"),
        (.classification, "分类协助"),
        (.taskPoolAnalysis, "任务池分析"),
        (.theoryAnalysis, "理论分析")
    ]

    var body: some View {
        List {
            Section("Provider") {
                TextField("OpenAI-compatible Base URL", text: $store.zhulongProviderBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $store.zhulongProviderModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key（只写入 Keychain）", text: $store.zhulongProviderAPIKey)
                Button("保存 Provider") { store.saveZhulongProvider() }
                Text(store.isZhulongProviderConfigured ? "Provider 已配置" : "Provider 未配置；远端请求会被阻断")
                    .font(.caption)
                    .foregroundStyle(store.isZhulongProviderConfigured ? .green : .secondary)
            }

            Section("新会话") {
                Picker("烛龙任务", selection: $store.zhulongTask) {
                    ForEach(taskOptions, id: \.0) { task, title in
                        Text(title).tag(task)
                    }
                }
                TextField("例如：帮我梳理今天的推进重点", text: $store.zhulongIntent, axis: .vertical)
                    .lineLimit(2 ... 5)
                Button("建立范围会话") { store.createZhulongSession() }
                    .disabled(store.zhulongIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("会话") {
                if store.zhulongSessions.isEmpty {
                    ContentUnavailableView("还没有烛龙会话", systemImage: "sparkles", description: Text("建立会话后，先授权数据范围，再发送消息。"))
                } else {
                    ForEach(store.zhulongSessions, id: \.id) { session in
                        Button {
                            store.selectedZhulongSessionID = session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.primaryIntent)
                                Text("\(session.phase.rawValue) · \(session.workspaceStatus.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let session = store.selectedZhulongSession {
                Section("当前会话 · 授权范围") {
                    Text(session.primaryIntent)
                        .font(.headline)
                    Text("授权范围：\(session.proposedScopes.map(zhulongScopeName).sorted().joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.authorization == nil || session.phase == .scopeReview {
                        Button("授权上述数据范围") { store.authorizeZhulongSession() }
                            .disabled(store.isZhulongProviderConfigured == false)
                    } else {
                        Text("已授权 Provider：\(session.authorization?.providerIdentity.model ?? "—")")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if session.purpose == .taskShaping {
                    planningSection(session)
                }

                if let diff = store.selectedZhulongTodoDiff {
                    Section("待确认 Todo 变更") {
                        Text("版本 \(diff.version) · \(diff.items.count) 项")
                            .font(.headline)
                        ForEach(diff.items, id: \.id) { item in
                            Text(todoDiffDescription(item.operation))
                                .font(.subheadline)
                        }
                        Button("授权一次性写入") {
                            store.authorizeZhulongTodoDiff()
                        }
                        .accessibilityIdentifier("ios.zhulong.todoDiff.authorize")
                        .disabled(store.selectedZhulongTodoDiffHasAuthorization)
                        Button("确认并写入 Todo") {
                            store.applyZhulongTodoDiff()
                        }
                        .accessibilityIdentifier("ios.zhulong.todoDiff.apply")
                        .disabled(store.selectedZhulongTodoDiffHasAuthorization == false)
                    }
                }

                if let draft = store.selectedZhulongDailyReviewDraft {
                    Section("待确认每日复盘") {
                        if let summary = draft.summary {
                            Text("总结：\(summary)")
                        }
                        if let tomorrowNote = draft.tomorrowNote {
                            Text("明日：\(tomorrowNote)")
                        }
                        Button("授权保存复盘") {
                            store.authorizeZhulongDailyReview()
                        }
                        .accessibilityIdentifier("ios.zhulong.dailyReview.authorize")
                        .disabled(store.selectedZhulongDailyReviewHasAuthorization)
                        Button("确认并保存复盘") {
                            store.applyZhulongDailyReview()
                        }
                        .accessibilityIdentifier("ios.zhulong.dailyReview.apply")
                        .disabled(store.selectedZhulongDailyReviewHasAuthorization == false)
                    }
                }

                if let report = store.selectedZhulongTaskPoolAnalysis {
                    Section("任务池分析") {
                        if report.findings.isEmpty {
                            Text("当前没有可验证的分析发现。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(report.findings.indices, id: \.self) { index in
                                let finding = report.findings[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(finding.conclusion)
                                        .font(.headline)
                                    Text("证据：\(finding.evidence.compactMap(\.title).joined(separator: "、"))")
                                    Text("建议：\(finding.recommendation)")
                                    Text("信心：\(finding.confidence.rawValue) · 不确定性：\(finding.uncertainty)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("会话流") {
                    ForEach(session.entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.author == .user ? "我" : "烛龙")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.content)
                        }
                    }
                    if store.zhulongLiveResponse.isEmpty == false {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("烛龙 · 生成中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(store.zhulongLiveResponse)
                        }
                    }
                    TextField("发送一条消息", text: $store.zhulongMessage, axis: .vertical)
                        .lineLimit(2 ... 6)
                    Button("发送") { store.appendZhulongMessageAndRun() }
                        .disabled(store.zhulongMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.authorization == nil)
                    if let status = store.zhulongMessageStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("烛龙")
        .onChange(of: store.selectedZhulongSessionID) { _, _ in
            loadPlanningDraft()
        }
        .onAppear {
            loadPlanningDraft()
        }
    }

    private func planningSection(_ session: ZhulongSession) -> some View {
        Section("规划简报与一次性委托") {
            if let brief = session.currentPlanningBrief {
                Text("v\(brief.version) · \(brief.goal)")
                    .font(.headline)
                Text("成功标准：\(brief.successCriteria.joined(separator: "；"))")
                    .font(.caption)
                Text("委托活动：\(brief.delegatedActivities.map(\.rawValue).sorted().joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.reviewedPlanningBrief == nil {
                    Button("审查规划简报") {
                        store.reviewZhulongPlanningBrief()
                    }
                } else if session.activePlanningDelegation == nil,
                          session.currentDecisionGate == nil
                {
                    Button("建立一次性规划委托") {
                        store.delegateZhulongPlanningBrief()
                    }
                } else if session.activePlanningDelegation != nil {
                    Button("执行一次性规划委托") {
                        store.runZhulongPlanning()
                    }
                }

                if let artifact = store.selectedZhulongPlanArtifact {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("规划产物 v\(artifact.version)")
                            .font(.headline)
                        Text(artifact.proposal.summary)
                        ForEach(artifact.proposal.stages, id: \.id) { stage in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stage.title).font(.subheadline.weight(.semibold))
                                Text(stage.deliverables.joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let gate = store.selectedZhulongDecisionGate {
                    Text("需要用户决策：\(gate.draft.prompt)")
                        .font(.subheadline.weight(.semibold))
                    ForEach(gate.draft.options, id: \.id) { option in
                        Button(option.title) {
                            store.resolveZhulongDecisionGate(optionID: option.id)
                        }
                    }
                }
                if session.currentDecisionGate == nil,
                   session.latestDecisionGateResolutionRequiringBriefRevision != nil
                {
                    Button("将决策纳入简报修订") {
                        store.incorporateZhulongDecisionGateResolution()
                    }
                }
            } else {
                TextField("规划目标", text: $planningGoal, axis: .vertical)
                    .lineLimit(2 ... 4)
                TextField("成功标准（每行一项）", text: $planningCriteria, axis: .vertical)
                    .lineLimit(2 ... 6)
                TextField("硬约束（每行一项，可空）", text: $planningConstraints, axis: .vertical)
                    .lineLimit(2 ... 6)
                ForEach(ZhulongPlanningActivity.allCases, id: \.self) { activity in
                    Toggle(activityName(activity), isOn: Binding(
                        get: { planningActivities.contains(activity) },
                        set: { enabled in
                            if enabled {
                                planningActivities.insert(activity)
                            } else {
                                planningActivities.remove(activity)
                            }
                        }
                    ))
                }
                Button("发布规划简报") {
                    store.publishZhulongPlanningBrief(
                        goal: planningGoal,
                        successCriteria: planningCriteria.split(whereSeparator: \.isNewline).map(String.init),
                        hardConstraints: planningConstraints.split(whereSeparator: \.isNewline).map(String.init),
                        delegatedActivities: planningActivities
                    )
                }
                .disabled(
                    planningGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || planningCriteria.split(whereSeparator: \.isNewline).isEmpty
                        || planningActivities.isEmpty
                )
            }
        }
    }

    private func loadPlanningDraft() {
        guard let session = store.selectedZhulongSession else { return }
        planningGoal = session.currentPlanningBrief?.goal ?? session.primaryIntent
        planningCriteria = session.currentPlanningBrief?.successCriteria.joined(separator: "\n") ?? ""
        planningConstraints = session.currentPlanningBrief?.hardConstraints.joined(separator: "\n") ?? ""
        planningActivities = session.currentPlanningBrief?.delegatedActivities ?? [.taskDecomposition]
    }

    private func activityName(_ activity: ZhulongPlanningActivity) -> String {
        switch activity {
        case .taskDecomposition: "任务拆解"
        case .sequencing: "排序"
        case .riskReview: "风险复核"
        case .initialScheduling: "初始排程"
        case .dependencyMapping: "依赖映射"
        case .rollingTriggers: "滚动触发"
        }
    }

    private func zhulongScopeName(_ scope: ZhulongDataScope) -> String {
        switch scope {
        case .currentDayTodo: "当前日 Todo"
        case .taskPool: "任务池"
        case .unfinishedPool: "未完成"
        case .completedPool: "已完成"
        case .taskClassifications: "分类目录"
        }
    }

    private func todoDiffDescription(_ operation: ZhulongTodoDiffOperation) -> String {
        switch operation {
        case let .createTask(title, description, _, subtasks, targetDate):
            let destination = targetDate.map { "排至 \($0.description)" } ?? "放入任务池"
            return "新建：\(title)（\(destination)，子任务 \(subtasks.count) 个）\(description.map { "：\($0)" } ?? "")"
        case let .addSubtask(_, title, difficulty):
            return "添加子任务：\(title)（\(difficulty.rawValue)）"
        case let .scheduleFromPool(_, targetDate):
            return "任务池排至：\(targetDate.description)"
        case let .continueTrace(_, targetDate):
            return "延续轨迹至：\(targetDate.description)"
        case .abandonChain:
            return "废弃任务轨迹"
        }
    }
}
