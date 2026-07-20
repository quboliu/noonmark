import NoonmarkMacRuntime
import NoonmarkMacUIContract
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

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    private var dateTimeFormatter: AppDateTimeFormatter {
        AppDateTimeFormatter(language: store.engine.preferences.language)
    }

    private var records: [ZhulongStreamRecord] { workspace.records(using: copy) }
    private var currentRecordID: String? { records.last?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: copy.name,
                subtitle: workspace.selectedSession?.primaryIntent,
                badge: workspace.selectedSessionStatus(using: copy),
                badgeColor: statusColor,
                titlePlacement: .centeredInMainSurface,
                titleAnchorIdentifier: "zhulong.session.title"
            ) {
                HStack(spacing: 7) {
                    HeaderButton(copy.allSessionsAction) { workspace.showHome() }
                        .accessibilityIdentifier("zhulong-session-show-home")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "zhulong-session-show-home",
                                verificationText: copy.allSessionsAction
                            )
                        }
                    if workspace.selectedSession?.workspaceStatus == .paused {
                        HeaderButton(copy.continueAction) { workspace.resumeCurrentSession() }
                    } else {
                        HeaderButton(copy.pauseAction) { workspace.pauseCurrentSession() }
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        streamContent
                        currentAction
                        entryComposer
                        if let notice = workspace.status {
                            Notice(text: copy.notice(notice), tone: .locked)
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
                        verificationText: copy.sessionStreamVerificationTitle
                    )
                }
                .onChange(of: records.count) {
                    guard let currentRecordID else { return }
                    withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: 0.32)) {
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
                verificationText: workspace.selectedSession?.primaryIntent ?? copy.sessionFallbackTitle
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
            Text(copy.sessionTimelineTitle)
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
                    Text(copy.confirmScopeTitle)
                        .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    StatusPill(text: copy.waitingForYou, color: Theme.accent)
                }
                Text(copy.scopeDisclosure)
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
                SmallActionButton(copy.useThisSessionOnly, tone: .accent) {
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
                        text: copy.scopeConfirmed(
                            providerEnabled: store.zhulongProviderDraft.enabled
                        ),
                        tone: .future
                    )
                    if store.zhulongProviderDraft.enabled {
                        SmallActionButton(copy.startGenerating, tone: .accent) {
                            store.runCurrentZhulongProvider()
                        }
                        .accessibilityIdentifier("zhulong-run-provider")
                    } else if workspace.selectedSession?.dailyCloseSnapshots.contains(where: { $0.date == store.today }) == false {
                        SmallActionButton(copy.captureTodayFacts) {
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
                Text(copy.sharedDecisionTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(text: copy.waitingForYou, color: Theme.warn)
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
                placeholder: copy.decisionSupplementPlaceholder,
                style: .body
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            Text(copy.decisionChoiceNotice)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.24)))
    }

    private func decisionGateRevisionAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.incorporateDecisionTitle)
                .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(copy.decisionRevisionNotice)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            SmallActionButton(copy.createRevisedBrief, tone: .accent) {
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
                Text(copy.dailyReviewTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.dailyReviewReceipts.isEmpty ? copy.awaitingConfirmation : copy.saved,
                    color: session.dailyReviewReceipts.isEmpty ? Theme.warn : Theme.ok
                )
            }
            if let suggestion = latestProviderSuggestion(session) {
                Text(copy.providerSuggestion(suggestion))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            if session.dailyReviewReceipts.isEmpty == false {
                Notice(text: copy.dailyReviewSavedNotice, tone: .future)
            } else if session.dailyReviewDrafts.isEmpty {
                MarkdownEditor(
                    text: $dailyReviewSummary,
                    placeholder: copy.dailyReviewSummaryPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $dailyReviewTomorrow,
                    placeholder: copy.dailyReviewTomorrowPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                SmallActionButton(copy.createReviewDraft, tone: .accent) {
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
                SmallActionButton(copy.confirmAndSaveReview, tone: .accent) {
                    store.confirmAndSaveCurrentZhulongDailyReview()
                }
                .accessibilityIdentifier("zhulong-confirm-save-daily-review")
            }
            Text(copy.reviewBoundaryNotice)
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
                Text(copy.condenseBriefTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                MarkdownEditor(text: $briefGoal, placeholder: copy.goalPlaceholder, style: .compact)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $briefSuccessCriteria,
                    placeholder: copy.successCriteriaPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $briefHardConstraints,
                    placeholder: copy.hardConstraintsPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                SmallActionButton(copy.savePlanningBrief, tone: .accent) {
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
                Text(copy.planningBriefTitle(version: brief.version))
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.reviewedPlanningBrief?.id == brief.id ? copy.reviewed : copy.awaitingReview,
                    color: session.reviewedPlanningBrief?.id == brief.id ? Theme.ok : Theme.warn
                )
            }
            MarkdownText(brief.goal)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text1)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.successCriteriaTitle)
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(brief.successCriteria, id: \.self) { criterion in
                    MarkdownText("- \(criterion)")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text2)
                }
            }
            if session.reviewedPlanningBrief?.id != brief.id {
                SmallActionButton(copy.confirmBrief, tone: .accent) {
                    workspace.reviewCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-review-planning-brief")
            } else if session.activePlanningDelegation == nil {
                SmallActionButton(copy.delegatePlanningOnce, tone: .accent) {
                    workspace.delegateCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-delegate-planning")
            } else if store.zhulongProviderDraft.enabled {
                SmallActionButton(copy.runThisPlanning, tone: .accent) {
                    store.runCurrentZhulongPlanningProvider()
                }
                .accessibilityIdentifier("zhulong-run-planning-provider")
            } else {
                Notice(text: copy.providerRequiredForPlanning, tone: .future)
            }
            Text(copy.planningDelegationBoundary)
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
                Text(copy.planArtifactTitle(version: artifact.version))
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: copy.todoDiffReviewStatus(hasDiff: session.currentTodoDiff != nil),
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
                        Text(copy.deliverables(stage.deliverables))
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
                    Text(copy.todoDiffTitle(version: diff.version, count: diff.items.count))
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    ForEach(diff.items, id: \.id) { item in
                        Label(todoOperationLabel(item.operation), systemImage: "plus.circle")
                            .font(.noonmarkSystem(size: 10.8))
                            .foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    SmallActionButton(copy.reviewAndRevise) {
                        todoDiffBeingEdited = diff
                    }
                    .disabled(workspace.hasActiveTodoAuthorization)
                    .accessibilityIdentifier("zhulong-edit-todo-diff")
                    SmallActionButton(copy.confirmAndApplyAtomically, tone: .accent) {
                        store.confirmAndApplyCurrentZhulongTodoDiff()
                    }
                    .accessibilityIdentifier("zhulong-confirm-apply-todo-diff")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "zhulong-confirm-apply-todo-diff",
                            verificationText: copy.confirmAndApplyAtomically
                        )
                    }
                }
            } else {
                SmallActionButton(copy.createReviewableTodoDiff, tone: .accent) {
                    store.publishCurrentZhulongTodoDiff()
                }
                .accessibilityIdentifier("zhulong-publish-todo-diff")
            }
            Text(copy.todoAtomicBoundary)
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
            copy.createTaskOperation(
                title: title,
                targetDate: targetDate?.description
            )
        case let .addSubtask(_, title, _):
            copy.addSubtaskOperation(title: title)
        case let .scheduleFromPool(_, targetDate):
            copy.scheduleFromPoolOperation(targetDate: targetDate.description)
        case let .continueTrace(_, targetDate):
            copy.continueTraceOperation(targetDate: targetDate.description)
        case .abandonChain:
            copy.abandonChainOperation
        }
    }

    private func openTodoDiffEditorForE2EIfReady() {
        guard AppLaunchArguments.contains("--e2e-open-zhulong-todo-diff-editor"),
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
                    placeholder: copy.appendEntryPlaceholder,
                    style: .compact,
                    showsSurface: false,
                    onCommit: appendEntry
                )
                    .accessibilityIdentifier("zhulong-session-entry")
                SmallActionButton(copy.appendAction) { appendEntry() }
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
            workspace.reportUIError(.planningBriefSaveFailed)
        }
    }

    private func normalizedLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "；") }
            .flatMap { $0.components(separatedBy: ";") }
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
        dateTimeFormatter.string(from: date, style: .shortTime)
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        copy.scopeTitle(scope.presentationCopyKey)
    }
}
